import 'package:ewt_auto_client/core/utils/proxy_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeProxy', () {
    test('合法的 ip:port 原样返回', () {
      expect(normalizeProxy('127.0.0.1:8080'), '127.0.0.1:8080');
      expect(normalizeProxy('proxy.example.com:3128'), 'proxy.example.com:3128');
      expect(normalizeProxy(' 10.0.0.1:8888  '), '10.0.0.1:8888');
    });

    test('http/https 前缀被剥掉 (默认 http)', () {
      expect(normalizeProxy('http://127.0.0.1:8080'), '127.0.0.1:8080');
      expect(normalizeProxy('https://proxy.example.com:3128'),
          'proxy.example.com:3128');
    });

    test('socks5/socks5h 前缀保留', () {
      expect(normalizeProxy('socks5://127.0.0.1:1080'), 'socks5://127.0.0.1:1080');
      expect(normalizeProxy('socks5h://127.0.0.1:1080'),
          'socks5h://127.0.0.1:1080');
      expect(normalizeProxy('SOCKS5://proxy.example.com:1080'),
          'socks5://proxy.example.com:1080');
    });

    test('带路径/查询的代理被裁剪', () {
      expect(normalizeProxy('http://127.0.0.1:8080/'), '127.0.0.1:8080');
      expect(normalizeProxy('socks5://127.0.0.1:1080/'), 'socks5://127.0.0.1:1080');
    });

    test('非法输入返回 null', () {
      expect(normalizeProxy(''), isNull);
      expect(normalizeProxy('127.0.0.1'), isNull); // 缺端口
      expect(normalizeProxy('127.0.0.1:abc'), isNull); // 端口非数字
      expect(normalizeProxy('127.0.0.1:0'), isNull); // 端口越界
      expect(normalizeProxy('127.0.0.1:70000'), isNull); // 端口越界
      expect(normalizeProxy('http://'), isNull);
      expect(normalizeProxy('socks5://127.0.0.1'), isNull); // 缺端口
      expect(normalizeProxy('socks5h://:1080'), isNull); // 缺 host
    });
  });

  group('parseProxySpec', () {
    test('无前缀默认为 http', () {
      final spec = parseProxySpec('127.0.0.1:8080');
      expect(spec, isNotNull);
      expect(spec!.scheme, ProxyScheme.http);
      expect(spec.host, '127.0.0.1');
      expect(spec.port, 8080);
    });

    test('识别 socks5 / socks5h / https', () {
      expect(parseProxySpec('socks5://1.2.3.4:1080')!.scheme,
          ProxyScheme.socks5);
      expect(parseProxySpec('socks5h://1.2.3.4:1080')!.scheme,
          ProxyScheme.socks5h);
      expect(parseProxySpec('https://1.2.3.4:443')!.scheme, ProxyScheme.http);
      expect(parseProxySpec('http://1.2.3.4:80')!.scheme, ProxyScheme.http);
    });

    test('非法输入返回 null', () {
      expect(parseProxySpec(''), isNull);
      expect(parseProxySpec('127.0.0.1'), isNull);
      expect(parseProxySpec('socks4://127.0.0.1:1080'), isNull);
      expect(parseProxySpec('socks5://127.0.0.1:70000'), isNull);
    });
  });

  group('parseProxyLines', () {
    test('逐行解析并去重 (混合协议)', () {
      const content = '''
# 注释行
127.0.0.1:8080
http://10.0.0.1:3128
socks5://5.6.7.8:1080
// 另一种注释
socks5h://9.10.11.12:1081
proxy.example.com:80

127.0.0.1:8080
socks5://5.6.7.8:1080
''';
      expect(parseProxyLines(content), [
        '127.0.0.1:8080',
        '10.0.0.1:3128',
        'socks5://5.6.7.8:1080',
        'socks5h://9.10.11.12:1081',
        'proxy.example.com:80',
      ]);
    });

    test('空内容/纯注释返回空列表', () {
      expect(parseProxyLines(''), isEmpty);
      expect(parseProxyLines('# only comment\n// another'), isEmpty);
    });

    test('非法行被过滤', () {
      const content =
          '127.0.0.1:8080\nnot-a-proxy\n127.0.0.1:99999\nsocks5://x\n';
      expect(parseProxyLines(content), ['127.0.0.1:8080']);
    });
  });

  group('parseProxyHostPort', () {
    test('正常解析 host 与 port', () {
      expect(parseProxyHostPort('127.0.0.1:8080'), ('127.0.0.1', 8080));
      expect(parseProxyHostPort('http://proxy.example.com:3128'),
          ('proxy.example.com', 3128));
      expect(parseProxyHostPort('  10.0.0.1:8888  '), ('10.0.0.1', 8888));
      expect(parseProxyHostPort('socks5://127.0.0.1:1080'),
          ('127.0.0.1', 1080));
      expect(parseProxyHostPort('socks5h://127.0.0.1:1081'),
          ('127.0.0.1', 1081));
    });

    test('非法输入返回空 host 与 0 端口', () {
      expect(parseProxyHostPort(''), ('', 0));
      expect(parseProxyHostPort('127.0.0.1'), ('', 0));
      expect(parseProxyHostPort('127.0.0.1:abc'), ('', 0));
      expect(parseProxyHostPort('127.0.0.1:70000'), ('', 0));
      expect(parseProxyHostPort('http://'), ('', 0));
    });
  });
}
