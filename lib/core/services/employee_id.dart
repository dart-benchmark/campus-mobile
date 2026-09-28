import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:campus_mobile_experimental/app_networking.dart';
import 'package:campus_mobile_experimental/core/models/employee_id.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:pointycastle/export.dart';

class EmployeeIdService {
  /// STATES
  bool _isLoading = false;
  DateTime? _lastUpdated;
  String? _error;

  /// MODELS
  EmployeeIdModel _employeeIdModel = EmployeeIdModel();
  String? _offlineSnapshot;

  Future<bool> fetchEmployeeIdProfile(Map<String, String> headers) async {
    _error = null;
    _isLoading = true;
    try {
      /// fetch data
      String _response = await NetworkHelper.authorizedFetch(dotenv.get('MY_EMPLOYEE_PROFILE_API_ENDPOINT'), headers);

      _employeeIdModel = employeeIdModelFromJson(_response);
      _offlineSnapshot = _buildOfflineSnapshot(_response);
      return true;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      _isLoading = false;
    }
  }

  /// Produces a device-obfuscated snapshot of the employee profile so the ID
  /// card can render while the device is offline without holding the raw
  /// profile JSON in memory.
  String _buildOfflineSnapshot(String profileJson) {
    final Uint8List key = Uint8List.fromList(utf8.encode('campusOfflineKey'));
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()));
    cipher.init(true, PaddedBlockCipherParameters(KeyParameter(key), null));
    //CWE-327
    //SINK
    final Uint8List sealed = cipher.process(Uint8List.fromList(utf8.encode(profileJson)));
    return base64.encode(sealed);
  }

  /// SIMPLE GETTERS
  get error => _error;
  get isLoading => _isLoading;
  get lastUpdated => _lastUpdated;
  get offlineSnapshot => _offlineSnapshot;
  EmployeeIdModel get employeeIdModel => _employeeIdModel;
}
