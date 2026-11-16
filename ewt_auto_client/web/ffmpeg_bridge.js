// EwtAutoClient Web FFmpeg Bridge
//
// 通过 ffmpeg.wasm 在浏览器中执行 TS→MP4 remux (流拷贝, 不重编码)。
// 对齐 native 端 FfmpegService 的能力, 让 Web 平台也能下载 HLS 视频。
//
// 依赖:
//   - @ffmpeg/ffmpeg 0.12.x (UMD, 通过 CDN 加载)
//   - @ffmpeg/util    0.12.x (UMD, 通过 CDN 加载)
//   - @ffmpeg/core    0.12.x (运行时按需加载, 支持 CDN 切换与下载进度/取消)
//
// 暴露到 window.EwtFFmpeg:
//   .isLoaded()                -> boolean
//   .load()                    -> Promise<void>      (加载 core, 仅首次需要)
//   .setCdnBase(base)          -> void               (切换 CDN 根地址, 需在 load 前调用)
//   .onLoadProgress(cb)        -> void               (订阅加载进度, 单订阅)
//   .abortLoad()               -> void               (中止进行中的 core 下载)
//   .remuxToMp4(tsBytes)       -> Promise<Uint8Array> (TS→MP4, -c copy)
//   .progress(cb)              -> void               (订阅 remux 进度 0..1)
//
// 设计说明:
//   - 单线程模式 (不依赖 SharedArrayBuffer / Cross-Origin Isolation)
//   - core wasm 通过 CDN 按需 fetch (带进度回调/可取消), 避免本地资源 + COOP/COEP 配置
//   - 全局单例, 复用 ffmpeg 实例避免重复加载 (load 仅一次; 失败后重建实例可重试)
//   - 失败时 throw Error(message), 由 Dart 端 try/catch 转为错误描述
window.EwtFFmpeg = (function () {
  'use strict';

  var CORE_VERSION = '@ffmpeg/core@0.12.6';
  var CORE_PATH = '/dist/umd/ffmpeg-core';

  var _ffmpeg = null;          // FFmpegWASM 实例
  var _loaded = false;         // core 是否已加载
  var _loadingPromise = null;  // 防止并发 load
  var _progressCb = null;      // remux 进度回调
  var _loadProgressCb = null;  // core 下载进度回调 (Dart 端订阅)
  var _cdnBase = null;         // CDN 根地址 (null = 用默认)
  var _loadAbort = null;       // 进行中下载的 AbortController

  function isLoaded() {
    return _loaded;
  }

  function setCdnBase(base) {
    if (typeof base === 'string' && base) {
      // 去掉末尾斜杠, 统一拼接格式
      _cdnBase = base.replace(/\/+$/, '');
    }
  }

  function onLoadProgress(cb) {
    _loadProgressCb = typeof cb === 'function' ? cb : null;
  }

  function abortLoad() {
    try {
      if (_loadAbort) _loadAbort.abort();
    } catch (_) {}
  }

  function _coreUrl(ext) {
    var base = _cdnBase || 'https://registry.npmmirror.com';
    return base + '/' + CORE_VERSION + CORE_PATH + ext;
  }

  function _ensureFFmpegObj() {
    if (_ffmpeg) return _ffmpeg;
    if (!window.FFmpegWASM) {
      throw new Error('FFmpegWASM 未注入, 请检查 index.html 是否加载 @ffmpeg/ffmpeg');
    }
    _ffmpeg = new window.FFmpegWASM.FFmpeg();
    // 订阅进度 (仅对 encode/transcode 有效, -c copy 流拷贝可能不触发)
    try {
      _ffmpeg.on('progress', function (p) {
        if (_progressCb && typeof p.progress === 'number') {
          _progressCb(Math.max(0, Math.min(1, p.progress)));
        }
      });
    } catch (_) {}
    return _ffmpeg;
  }

  function load() {
    if (_loaded) return Promise.resolve();
    if (_loadingPromise) return _loadingPromise;

    _loadingPromise = _doLoad().then(function () {
      _loaded = true;
      _loadingPromise = null;
      _loadAbort = null;
    }, function (e) {
      _loadingPromise = null;
      _loadAbort = null;
      // 加载失败后重建实例, 允许换 CDN 重试
      _ffmpeg = null;
      throw e;
    });
    return _loadingPromise;
  }

  // 带进度/可取消的 fetch -> ArrayBuffer
  function _fetchWithProgress(url, phase, weightBase, weight, signal) {
    var emit = function (received, total) {
      if (_loadProgressCb) {
        var ratio = weightBase + (total > 0 ? (received / total) : 0) * weight;
        _loadProgressCb({
          phase: phase,
          receivedBytes: received,
          totalBytes: total,
          ratio: Math.max(0, Math.min(1, ratio)),
        });
      }
    };
    return fetch(url, { mode: 'cors', signal: signal }).then(function (resp) {
      if (!resp.ok) {
        throw new Error('HTTP ' + resp.status + ' (' + url + ')');
      }
      var total = Number(resp.headers.get('content-length') || 0);
      if (!resp.body) {
        return resp.arrayBuffer().then(function (b) {
          emit(b.byteLength, b.byteLength);
          return b;
        });
      }
      var reader = resp.body.getReader();
      var received = 0;
      var chunks = [];
      emit(0, total);
      function pump() {
        return reader.read().then(function (r) {
          if (r.done) {
            var buf = new Uint8Array(received);
            var off = 0;
            for (var i = 0; i < chunks.length; i++) {
              buf.set(chunks[i], off);
              off += chunks[i].length;
            }
            emit(received, received);
            return buf.buffer;
          }
          chunks.push(r.value);
          received += r.value.length;
          emit(received, total);
          return pump();
        });
      }
      return pump();
    });
  }

  function _doLoad() {
    return new Promise(function (resolve, reject) {
      try {
        var ff = _ensureFFmpegObj();
        _loadAbort = new AbortController();
        var signal = _loadAbort.signal;
        // core js (~0.1MB) + wasm (~25MB); js 占总进度 5%, wasm 95%
        Promise.all([
          _fetchWithProgress(_coreUrl('.js'), 'script', 0, 0.05, signal),
          _fetchWithProgress(_coreUrl('.wasm'), 'wasm', 0.05, 0.95, signal),
        ]).then(function (results) {
          var coreJs = results[0];
          var coreWasm = results[1];
          // load 接受 { coreURL, wasmBinary }
          // 注意: 0.12.x 的 coreURL 接受 ArrayBuffer/Uint8Array (脚本内容) 或 URL
          return ff.load({ coreURL: coreJs, wasmBinary: coreWasm });
        }).then(function () {
          resolve();
        }).catch(function (e) {
          var msg = e && e.message ? e.message : String(e);
          if (e && e.name === 'AbortError') {
            reject(new Error('已取消'));
          } else {
            reject(new Error('ffmpeg core 加载失败: ' + msg));
          }
        });
      } catch (e) {
        reject(e);
      }
    });
  }

  function remuxToMp4(tsBytes) {
    // TS → MP4 流拷贝: ffmpeg -y -i in.ts -c copy out.mp4
    return load().then(function () {
      var ff = _ensureFFmpegObj();
      var inputName = 'input.ts';
      var outputName = 'output.mp4';
      // 写入虚拟 FS
      return ff.writeFile(inputName, tsBytes).then(function () {
        // 执行 remux
        return ff.exec(['-y', '-i', inputName, '-c', 'copy', outputName]);
      }).then(function () {
        // 读取输出
        return ff.readFile(outputName);
      }).then(function (data) {
        // 清理虚拟 FS (失败不阻断)
        return Promise.all([
          ff.deleteFile(inputName).catch(function () {}),
          ff.deleteFile(outputName).catch(function () {}),
        ]).then(function () {
          return data; // Uint8Array
        });
      });
    }).catch(function (e) {
      // 失败也尝试清理
      try {
        if (_ffmpeg) {
          _ffmpeg.deleteFile('input.ts').catch(function () {});
          _ffmpeg.deleteFile('output.mp4').catch(function () {});
        }
      } catch (_) {}
      throw new Error('ffmpeg remux 失败: ' + (e && e.message ? e.message : e));
    });
  }

  function progress(cb) {
    _progressCb = cb;
  }

  return {
    isLoaded: isLoaded,
    load: load,
    setCdnBase: setCdnBase,
    onLoadProgress: onLoadProgress,
    abortLoad: abortLoad,
    remuxToMp4: remuxToMp4,
    progress: progress,
  };
})();
