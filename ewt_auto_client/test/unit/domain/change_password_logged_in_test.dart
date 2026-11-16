/// 账号中心主动改密（设置页"修改密码"）与 web 对齐测试 (离线)
///
/// 对齐对象：web `member-center` SPA `ChangePassword/service`（已从线上 JS 抓取验证）：
///   - 端点: POST /api/usercenter/user/operate/change/password
///   - 加密: CryptoJS AES-256-CBC/PKCS7,
///           key=`20171109124536982017110912453698`, iv=`2017110912453698`，
///           输出大写 HEX（与 [PasswordEncryptor] 完全一致，可复用）
/// 这些常量若被误改，改密接口将直接失败（或旧密码校验不通过），故用测试钉死。
library;

import 'package:ewt_auto_client/core/constants/api_constants.dart';
import 'package:ewt_auto_client/core/constants/crypto_constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('账号中心主动改密端点', () {
    test('端点为 member-center SPA 实际调用的路径', () {
      expect(
        ApiConstants.changePasswordLoggedInUrl,
        '/api/usercenter/user/operate/change/password',
      );
    });

    test('与弱密码改密端点不同（主动改密无需 checkToken）', () {
      expect(
        ApiConstants.changePasswordLoggedInUrl,
        isNot(ApiConstants.changePasswordMobileUrl),
      );
      expect(
        ApiConstants.changePasswordLoggedInUrl,
        isNot(ApiConstants.changePasswordAccountUrl),
      );
    });
  });

  group('改密加密与 web Encrypt 对齐', () {
    test('AES 密钥与 member-center SPA 硬编码一致', () {
      expect(CryptoConstants.aesKey, '20171109124536982017110912453698');
    });

    test('AES IV 与 member-center SPA 硬编码一致', () {
      expect(CryptoConstants.aesIv, '2017110912453698');
    });
  });
}
