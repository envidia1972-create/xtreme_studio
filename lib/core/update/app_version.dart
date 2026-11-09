/// Version de la aplicacion y origen de actualizaciones.
///
/// Los scripts de compilacion leen `pubspec.yaml` y pasan estos valores con
/// `--dart-define`. Para desarrollo, el valor por defecto es 0.1.0.
library;

/// Version visible (sin el build number).
const String appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '0.1.0',
);

/// Build number de `pubspec.yaml`.
const String appBuild = String.fromEnvironment('APP_BUILD', defaultValue: '1');

/// Origen de la ultima release.
///
/// Por defecto es la API publica de GitHub Releases del proyecto. Se puede
/// reemplazar con:
///
/// ```
/// flutter build windows --dart-define=UPDATE_URL=https://mi-sitio.com/latest.json
/// ```
const String updateManifestUrl = String.fromEnvironment(
  'UPDATE_URL',
  defaultValue:
      'https://api.github.com/repos/envidia1972-create/xtreme_studio/releases/latest',
);

/// Repositorio publico usado para abrir la pagina de descarga si la API falla.
const String updateReleasePage =
    'https://github.com/envidia1972-create/xtreme_studio/releases/latest';
