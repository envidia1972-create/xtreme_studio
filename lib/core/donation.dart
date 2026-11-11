/// Enlace oficial de donaciones y apertura en el navegador del sistema.
///
/// El boton de PayPal es un enlace permanente con `hosted_button_id`; no
/// contiene el correo de la cuenta y no usa los enlaces temporales con
/// `token=`, que vencen en pocas horas.
library;

import 'dart:io';

/// Cuenta de donaciones de Xtreme Studio.
const String donationUrl =
    'https://www.paypal.com/donate/?hosted_button_id=URNUVG7CSFFFQ';

/// Abre la pagina de donaciones en el navegador predeterminado.
///
/// No se usa un plugin nativo: la app ya abre archivos con `xdg-open` y
/// `explorer.exe`, y asi se mantiene la regla de no agregar plugins.
/// Devuelve `false` si el sistema no pudo abrir el navegador.
Future<bool> openDonationPage() async {
  try {
    if (Platform.isWindows) {
      await Process.start('rundll32', [
        'url.dll,FileProtocolHandler',
        donationUrl,
      ], mode: ProcessStartMode.detached);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [
        donationUrl,
      ], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      await Process.start('open', [
        donationUrl,
      ], mode: ProcessStartMode.detached);
    } else {
      return false;
    }
    return true;
  } on ProcessException {
    return false;
  } on OSError {
    return false;
  }
}
