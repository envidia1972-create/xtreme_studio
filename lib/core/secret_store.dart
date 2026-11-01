/// Almacen de secretos: contrasenas de los perfiles de servidor.
///
/// En Windows usa **DPAPI** (`CryptProtectData`) via FFI. Eso significa que el
/// texto cifrado solo puede descifrarlo el mismo usuario en la misma maquina:
/// si alguien copia el archivo de perfiles a su PC, no obtiene nada.
///
/// Los secretos se guardan en un archivo aparte del de configuracion, uno por
/// perfil, para que un perfil corrupto no invalide los demas.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Resultado de proteger/desproteger: el payload y, si algo fallo, el motivo.
class SecretResult {
  const SecretResult(this.data, {this.error});
  final Uint8List? data;
  final String? error;

  bool get ok => data != null;
}

abstract class SecretStore {
  /// Cifra [plain] y devuelve el blob listo para guardar en disco.
  SecretResult protect(String plain);

  /// Descifra un blob producido por [protect].
  SecretResult unprotect(Uint8List blob);

  /// `true` si el backend a prueba de manipulacion esta disponible.
  bool get isSecure;
}

/// Fabrica el backend adecuado para la plataforma actual.
SecretStore createSecretStore({Directory? directory}) {
  if (Platform.isWindows) {
    return DpapiSecretStore();
  }
  // En Linux/macOS no existe DPAPI. Se usa un backend honesto: guarda la
  // contrasena en un archivo aparte con permisos de solo lectura para el
  // usuario (0600). No se finge cifrado: `isSecure` devuelve false y la
  // interfaz lo avisa.
  return PermissionsSecretStore();
}

/// Backend Windows basado en DPAPI.
class DpapiSecretStore implements SecretStore {
  /// Entropia adicional: ata el blob a esta aplicacion. Otro programa del
  /// mismo usuario no puede descifrar nuestras contrasenas sin conocerla.
  static const String _entropyLabel = 'XtremeStudio.ProfilePassword.v1';

  /// `CRYPTPROTECT_UI_FORBIDDEN`: nunca mostrar dialogo de interfaz.
  static const int _uiForbidden = 0x1;

  @override
  bool get isSecure => true;

  @override
  SecretResult protect(String plain) {
    final inputBytes = utf8.encode(plain);
    if (inputBytes.isEmpty) {
      return const SecretResult(null, error: 'No hay nada que cifrar');
    }

    final dataIn = calloc<CRYPT_INTEGER_BLOB>();
    final dataOut = calloc<CRYPT_INTEGER_BLOB>();
    final entropy = calloc<CRYPT_INTEGER_BLOB>();
    final inBuf = calloc<Uint8>(inputBytes.length);
    final entropyBuf = calloc<Uint8>(_entropyLabel.length);

    try {
      inBuf.asTypedList(inputBytes.length).setAll(0, inputBytes);
      dataIn.ref
        ..cbData = inputBytes.length
        ..pbData = inBuf;

      final entropyBytes = utf8.encode(_entropyLabel);
      entropyBuf.asTypedList(entropyBytes.length).setAll(0, entropyBytes);
      entropy.ref
        ..cbData = entropyBytes.length
        ..pbData = entropyBuf;

      final ok = CryptProtectData(
        dataIn,
        nullptr,
        entropy,
        nullptr,
        nullptr,
        _uiForbidden,
        dataOut,
      );

      if (ok == 0) {
        return SecretResult(null, error: 'DPAPI no pudo cifrar (error ${GetLastError()})');
      }

      final outLen = dataOut.ref.cbData;
      final outBytes = Uint8List.fromList(
        dataOut.ref.pbData.asTypedList(outLen),
      );
      // DPAPI reserva el buffer de salida con LocalAlloc: hay que liberarlo.
      calloc.free(dataOut.ref.pbData);
      return SecretResult(outBytes);
    } catch (e) {
      return SecretResult(null, error: 'Error al cifrar: $e');
    } finally {
      calloc.free(dataIn);
      calloc.free(dataOut);
      calloc.free(entropy);
      calloc.free(inBuf);
      calloc.free(entropyBuf);
    }
  }

  @override
  SecretResult unprotect(Uint8List blob) {
    if (blob.isEmpty) return const SecretResult(null, error: 'Blob vacio');

    final dataIn = calloc<CRYPT_INTEGER_BLOB>();
    final dataOut = calloc<CRYPT_INTEGER_BLOB>();
    final entropy = calloc<CRYPT_INTEGER_BLOB>();
    final inBuf = calloc<Uint8>(blob.length);
    final entropyBuf = calloc<Uint8>(_entropyLabel.length);

    try {
      inBuf.asTypedList(blob.length).setAll(0, blob);
      dataIn.ref
        ..cbData = blob.length
        ..pbData = inBuf;

      final entropyBytes = utf8.encode(_entropyLabel);
      entropyBuf.asTypedList(entropyBytes.length).setAll(0, entropyBytes);
      entropy.ref
        ..cbData = entropyBytes.length
        ..pbData = entropyBuf;

      final ok = CryptUnprotectData(
        dataIn,
        nullptr,
        entropy,
        nullptr,
        nullptr,
        _uiForbidden,
        dataOut,
      );

      if (ok == 0) {
        return SecretResult(
          null,
          error:
              'No se pudo descifrar la contrasena (error ${GetLastError()}). '
              'Suele pasar si el archivo se copio de otra PC o de otro usuario.',
        );
      }

      final outLen = dataOut.ref.cbData;
      final outBytes = Uint8List.fromList(
        dataOut.ref.pbData.asTypedList(outLen),
      );
      calloc.free(dataOut.ref.pbData);
      return SecretResult(outBytes);
    } catch (e) {
      return SecretResult(null, error: 'Error al descifrar: $e');
    } finally {
      calloc.free(dataIn);
      calloc.free(dataOut);
      calloc.free(entropy);
      calloc.free(inBuf);
      calloc.free(entropyBuf);
    }
  }

  /// Helper: descifra y decodifica a texto.
  String? unprotectString(Uint8List blob) {
    final r = unprotect(blob);
    if (!r.ok) return null;
    return utf8.decode(r.data!, allowMalformed: true);
  }
}

/// Backend de reserva cuando no hay cifrado disponible en la plataforma.
///
/// Deliberadamente **no** finge cifrar: la app debe avisar al usuario en vez de
/// dar una falsa sensacion de seguridad.
class UnavailableSecretStore implements SecretStore {
  UnavailableSecretStore(this.reason);

  final String reason;

  @override
  bool get isSecure => false;

  @override
  SecretResult protect(String plain) => SecretResult(null, error: reason);

  @override
  SecretResult unprotect(Uint8List blob) => SecretResult(null, error: reason);
}

/// Backend para plataformas sin DPAPI (Linux/macOS).
///
/// No hay un almacen de claves comun a todas las distribuciones que se pueda
/// usar sin dependencias nativas, asi que se guarda el secreto marcado y con
/// permisos 0600. Es honesto con el usuario: [isSecure] es `false` y la
/// interfaz lo indica.
///
/// El prefijo permite distinguir el formato y fallar de forma limpia si el
/// archivo se manipula.
class PermissionsSecretStore implements SecretStore {
  static const String _prefix = 'xtreme-plain-v1:';

  @override
  bool get isSecure => false;

  @override
  SecretResult protect(String plain) {
    if (plain.isEmpty) return const SecretResult(null, error: 'No hay nada que cifrar');
    final bytes = utf8.encode('$_prefix$plain');
    return SecretResult(Uint8List.fromList(bytes));
  }

  @override
  SecretResult unprotect(Uint8List blob) {
    if (blob.isEmpty) return const SecretResult(null, error: 'Blob vacio');
    final text = utf8.decode(blob, allowMalformed: true);
    if (!text.startsWith(_prefix)) {
      return const SecretResult(
        null,
        error: 'El archivo de credenciales no tiene un formato conocido',
      );
    }
    return SecretResult(
      Uint8List.fromList(utf8.encode(text.substring(_prefix.length))),
    );
  }
}
