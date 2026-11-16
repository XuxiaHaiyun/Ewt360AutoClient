/// IO 平台代理适配: HTTP 代理走 findProxy (回环地址直连),
/// SOCKS5/SOCKS5h 走自定义连接工厂完成握手; 可选跳过 SSL 证书校验。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../utils/proxy_parser.dart';

/// IO 平台 (Windows/Android/iOS/macOS/Linux) 的代理适配实现
///
/// - HTTP 代理: 通过 `HttpClient.findProxy` 注入 (Dio 所有请求走指定代理)
/// - SOCKS5 / SOCKS5h: 通过 `HttpClient.connectionFactory` 自定义底层连接,
///   在返回 Socket 前与代理完成 SOCKS5 握手
/// - [trustAllCerts]: 跳过 SSL 证书校验 (自签名证书/抓包场景)
///
/// [proxy] 为 null/空串或格式非法时不配置代理 (直连)。重复调用会整体重建
/// 适配器, 因此支持运行时切换/清除代理与证书策略 (仅替换引用, 旧适配器的
/// 存量连接空闲后自然释放, 不强制断开在途请求)。
void applyProxyAdapter(
  Dio dio,
  String? proxy, {
  bool trustAllCerts = false,
}) {
  final spec =
      (proxy == null || proxy.trim().isEmpty) ? null : parseProxySpec(proxy);

  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      if (trustAllCerts) {
        client.badCertificateCallback = (cert, host, port) => true;
      }
      if (spec != null) {
        switch (spec.scheme) {
          case ProxyScheme.http:
            _configHttpProxy(client, spec);
          case ProxyScheme.socks5:
          case ProxyScheme.socks5h:
            _configSocksProxy(client, spec);
        }
      }
      return client;
    },
  );
}

/// HTTP 代理: 回环地址直连, 其余走代理
void _configHttpProxy(HttpClient client, ProxySpec spec) {
  client.findProxy = (uri) {
    final uhost = uri.host;
    final isLoopback = uhost == 'localhost' || uhost == '127.0.0.1';
    return isLoopback ? 'DIRECT' : 'PROXY ${spec.host}:${spec.port}';
  };
}

/// SOCKS5 代理: 自定义连接工厂, 建立 TCP 后完成 SOCKS5 握手
void _configSocksProxy(HttpClient client, ProxySpec spec) {
  client.connectionFactory = (uri, proxyHost, proxyPort) {
    return _socks5Connect(spec, uri);
  };
}

Future<ConnectionTask<Socket>> _socks5Connect(ProxySpec spec, Uri uri) async {
  var targetHost = uri.host;
  final targetPort = uri.port;

  // socks5: 域名在本地解析为 IP 再交给代理;
  // socks5h: 域名直接发给代理, 由代理端做 DNS 解析。
  if (spec.scheme == ProxyScheme.socks5 &&
      InternetAddress.tryParse(targetHost) == null) {
    final addrs = await InternetAddress.lookup(targetHost);
    if (addrs.isEmpty) {
      throw SocketException('SOCKS5: 域名解析失败 $targetHost');
    }
    // 优先 IPv4 (SOCKS5 对 IPv4 兼容性最好)
    targetHost = addrs
        .firstWhere(
          (a) => a.type == InternetAddressType.IPv4,
          orElse: () => addrs.first,
        )
        .address;
  }

  final socket = await Socket.connect(spec.host, spec.port);
  final socks = _Socks5Socket(socket);
  try {
    await socks.handshake(targetHost, targetPort);
  } catch (e) {
    socket.destroy();
    rethrow;
  }
  return ConnectionTask.fromSocket(Future.value(socks), socks.destroy);
}

/// 包装已建立 TCP 连接的 SOCKS5 Socket。
///
/// dart:io 的 [Socket] 是单订阅流, 订阅取消后不能再 listen, 而 SOCKS5
/// 握手需要先消费代理响应、之后连接才能交给 HttpClient 继续收发, 故在此
/// 包装: 构造函数即订阅底层 socket, 握手期间把所有入站数据缓冲起来,
/// HttpClient 首次 [listen] 时先吐出缓冲, 再把后续数据实时转发。
class _Socks5Socket extends Stream<Uint8List> implements Socket {
  final Socket _inner;

  /// 已收到但尚未消费的入站数据 (握手缓冲)
  final ListQueue<Uint8List> _chunks = ListQueue<Uint8List>();
  Completer<void>? _waiter;
  StreamSubscription<Uint8List>? _sub;
  bool _closed = false;

  _Socks5Socket(this._inner) {
    _sub = _inner.listen(
      (chunk) {
        _chunks.add(chunk);
        final w = _waiter;
        if (w != null && !w.isCompleted) w.complete();
      },
      onError: (Object e, StackTrace st) {
        final w = _waiter;
        if (w != null && !w.isCompleted) w.completeError(e, st);
      },
      onDone: () {
        _closed = true;
        final w = _waiter;
        if (w != null && !w.isCompleted) w.complete();
      },
    );
  }

  /// 与代理完成 SOCKS5 握手 (必须在首次 [listen] 之前调用)
  Future<void> handshake(String targetHost, int targetPort) async {
    // 1. 方法协商: 仅支持无认证方式
    _inner.add(const [0x05, 0x01, 0x00]);
    await _inner.flush();
    final ver = await _readByte();
    final method = await _readByte();
    if (ver != 0x05) {
      throw SocketException('SOCKS5: 代理返回非法版本 0x${ver.toRadixString(16)}');
    }
    if (method != 0x00) {
      throw SocketException('SOCKS5: 代理不支持无认证方式 (method=0x${method.toRadixString(16)})');
    }

    // 2. CONNECT 请求: VER CMD RSV ATYP DST.ADDR DST.PORT
    final addr = _encodeTarget(targetHost);
    _inner.add(<int>[
      0x05, 0x01, 0x00, // VER=5 CMD=CONNECT RSV=0
      ...addr,
      (targetPort >> 8) & 0xFF,
      targetPort & 0xFF,
    ]);
    await _inner.flush();

    // 3. 响应: VER REP RSV ATYP BND.ADDR BND.PORT
    final rVer = await _readByte();
    final rep = await _readByte();
    if (rVer != 0x05 || rep != 0x00) {
      throw SocketException('SOCKS5: 连接目标失败 (rep=0x${rep.toRadixString(16)})');
    }
    await _readByte(); // RSV
    final atyp = await _readByte();
    switch (atyp) {
      case 0x01: // IPv4
        for (var i = 0; i < 4; i++) {
          await _readByte();
        }
      case 0x03: // DOMAIN
        final len = await _readByte();
        for (var i = 0; i < len; i++) {
          await _readByte();
        }
      case 0x04: // IPv6
        for (var i = 0; i < 16; i++) {
          await _readByte();
        }
      default:
        throw SocketException('SOCKS5: 非法响应地址类型 0x${atyp.toRadixString(16)}');
    }
    await _readByte(); // BND.PORT 高字节
    await _readByte(); // BND.PORT 低字节
  }

  /// 编码目标地址: IP 走 IPV4/IPV6, 域名走 DOMAIN
  List<int> _encodeTarget(String host) {
    final ip = InternetAddress.tryParse(host);
    if (ip != null) {
      if (ip.type == InternetAddressType.IPv4) {
        return [0x01, ...ip.rawAddress];
      }
      if (ip.type == InternetAddressType.IPv6) {
        return [0x04, ...ip.rawAddress];
      }
    }
    final bytes = utf8.encode(host);
    return [0x03, bytes.length, ...bytes];
  }

  Future<int> _readByte() async {
    while (_chunks.isEmpty) {
      if (_closed) {
        throw SocketException('SOCKS5: 握手期间连接被代理关闭');
      }
      final w = Completer<void>();
      _waiter = w;
      await w.future;
    }
    final first = _chunks.removeFirst();
    final b = first.first;
    if (first.length > 1) {
      _chunks.addFirst(Uint8List.fromList(first.sublist(1)));
    }
    return b;
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<Uint8List>();
    final sub = _sub!;
    sub.onData((chunk) => controller.add(chunk));
    sub.onError((Object e, StackTrace st) => controller.addError(e, st));
    sub.onDone(() => controller.close());
    // 先吐出握手期间缓冲的遗留数据, 再实时转发
    while (_chunks.isNotEmpty) {
      controller.add(_chunks.removeFirst());
    }
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  // ---- Socket 接口成员: 全部转发到底层 socket ----
  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  void write(Object? obj) => _inner.write(obj);
  @override
  void writeln([Object? obj = '']) => _inner.writeln(obj);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);
  @override
  void add(List<int> bytes) => _inner.add(bytes);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  void destroy() => _inner.destroy();
  @override
  Future flush() => _inner.flush();
  @override
  Future close() => _inner.close();
  @override
  Future get done => _inner.done;

  @override
  int get port => _inner.port;
  @override
  InternetAddress get address => _inner.address;
  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;
  @override
  int get remotePort => _inner.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);
}
