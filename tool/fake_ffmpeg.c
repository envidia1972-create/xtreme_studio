// ffmpeg falso para pruebas.
//
// Ahora Xtreme Studio usa DOS procesos FFmpeg:
//   - captura:  microfono -> PCM f32le por *stdout*
//   - encoder:  PCM f32le por *stdin* -> MP3 por *stdout*
//
// Este doble imita los dos papeles para poder probar toda la cadena sin
// microfono ni codificador reales:
//   - en modo captura escribe una onda cuadrada de -6 dBFS por stdout
//   - en modo encoder lee el PCM de stdin y produce tramas MP3 validas
//   - guarda los argumentos con los que lo invocaron para verificar la linea
//     de comandos
//   - sale solo cuando se cierra su entrada o al recibir Ctrl+C
//
// Variables de entorno:
//   XTREME_FFMPEG_ROLE      "capture", "encoder" (lo pone el motor)
//   FAKEFFMPEG_ARGS_FILE    archivo base donde escribir los argumentos; se le
//                           agrega el sufijo .<role> para no mezclar procesos
//   FAKEFFMPEG_DURATION_MS  cuanto tiempo emitir la captura (0 = infinito)
//   FAKEFFMPEG_DIAGNOSE_MESSAGE  error que devuelve el diagnostico de un tiro

#ifdef _WIN32
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#define XS_SLEEP_MS(ms) Sleep(ms)
#else
#include <unistd.h>
#define XS_SLEEP_MS(ms) usleep((useconds_t)((ms) * 1000))
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *role_name(int argc, char **argv) {
    const char *role = getenv("XTREME_FFMPEG_ROLE");
    if (role != NULL && role[0] != '\0') return role;

    // Sin variable: se deduce de la linea de comandos. Sirve para el
    // diagnostico de un solo disparo, que no pasa por el motor.
    for (int i = 0; i + 1 < argc; i++) {
        if (strcmp(argv[i], "-i") == 0 && strcmp(argv[i + 1], "pipe:0") == 0) {
            return "encoder";
        }
    }
    return "other";
}

static int has_arg(int argc, char **argv, const char *wanted) {
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], wanted) == 0) return 1;
    }
    return 0;
}

static int int_after(int argc, char **argv, const char *flag, int fallback) {
    for (int i = 0; i + 1 < argc; i++) {
        if (strcmp(argv[i], flag) == 0) {
            int value = atoi(argv[i + 1]);
            if (value > 0) return value;
        }
    }
    return fallback;
}

static void append_args_file(int argc, char **argv) {
    const char *base = getenv("FAKEFFMPEG_ARGS_FILE");
    if (base == NULL || base[0] == '\0') return;

    char path[4096];
    snprintf(path, sizeof(path), "%s.%s", base, role_name(argc, argv));

    FILE *f = fopen(path, "wb");
    if (f == NULL) return;
    for (int i = 0; i < argc; i++) {
        fputs(argv[i], f);
        fputc('\n', f);
    }
    fclose(f);
}

/// Escribe un bloque de MP3 verosimil: cabecera de sincronizacion 0xFF 0xFB.
static void write_mp3(unsigned char *buf, int size, unsigned int counter) {
    buf[0] = 0xFF;
    buf[1] = 0xFB;
    buf[2] = 0x90;
    buf[3] = 0x64;
    for (int i = 4; i < size; i++) {
        buf[i] = (unsigned char)((i + counter) & 0xFF);
    }
}

/// Escribe PCM `f32le` estereo/mono con una onda cuadrada de -6 dBFS.
///
/// La amplitud 0.5 es la que el vumetro debe medir como -6 dBFS. Se escribe de
/// verdad en coma flotante porque asi viaja el audio en la app.
static void write_pcm_f32(unsigned char *buf, int bytes, int channels,
                          unsigned int counter) {
    int samples = bytes / 4;
    for (int i = 0; i < samples; i++) {
        float value;
        if ((counter + (unsigned int)i) % 100 < 50) {
            value = 0.5f;
        } else {
            value = -0.5f;
        }
        unsigned char raw[4];
        memcpy(raw, &value, 4);
        buf[i * 4 + 0] = raw[0];
        buf[i * 4 + 1] = raw[1];
        buf[i * 4 + 2] = raw[2];
        buf[i * 4 + 3] = raw[3];
    }
    (void)channels;
}

int main(int argc, char **argv) {
    // Salida binaria y sin buffer: el motor en Dart debe recibir los datos ya.
#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stderr), _O_BINARY);
#endif
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    append_args_file(argc, argv);

    const char *role = role_name(argc, argv);
    int isEncoder = strcmp(role, "encoder") == 0;

    // Modo diagnostico: el motor relanza FFmpeg pidiendo un instante de audio
    // (con `-t`) para capturar el motivo real de un fallo. Aqui se reproduce el
    // caso tipico: el dispositivo no existe.
    {
        const char *diag = getenv("FAKEFFMPEG_DIAGNOSE_MESSAGE");
        if (!isEncoder && has_arg(argc, argv, "-t") && diag != NULL &&
            diag[0] != '\0') {
            fputs(diag, stderr);
            fputc('\n', stderr);
            fflush(stderr);
            return 1;
        }
    }

    int sampleRate = int_after(argc, argv, "-ar", 44100);
    int channels = int_after(argc, argv, "-ac", 2);

    if (isEncoder) {
        // Lee el PCM que le manda el motor y produce MP3 a ~128 kbps.
        // 320 bytes de MP3 por cada 20 ms de PCM (128 kbps).
        const int mp3Bytes = 320;
        const int bytesPer20ms = (sampleRate / 50) * channels * 4;
        unsigned char in[16384];
        unsigned char mp3[512];
        unsigned int mp3Counter = 0;
        long long pending = 0;

        for (;;) {
            size_t got = fread(in, 1, sizeof(in), stdin);
            if (got == 0) break;  // El motor cerro la entrada.
            pending += (long long)got;
            while (pending >= bytesPer20ms) {
                pending -= bytesPer20ms;
                write_mp3(mp3, mp3Bytes, mp3Counter++);
                if (fwrite(mp3, 1, mp3Bytes, stdout) != (size_t)mp3Bytes) {
                    return 0;
                }
                fflush(stdout);
            }
        }
        return 0;
    }

    // Modo captura: entrega PCM f32le continuo por stdout.
    int durationMs = 0;
    const char *dur = getenv("FAKEFFMPEG_DURATION_MS");
    if (dur != NULL && dur[0] != '\0') durationMs = atoi(dur);

    // 20 ms de audio por bloque, como un dispositivo real.
    const int samplesPerBlock = (sampleRate / 50) * channels;
    const int pcmBytes = samplesPerBlock * 4;
    unsigned char *pcm = (unsigned char *)malloc((size_t)pcmBytes);
    if (pcm == NULL) return 2;

    unsigned int pcmCounter = 0;
    unsigned long long elapsedMs = 0;

    for (;;) {
        write_pcm_f32(pcm, pcmBytes, channels, pcmCounter);
        pcmCounter += (unsigned int)samplesPerBlock;

        if (fwrite(pcm, 1, (size_t)pcmBytes, stdout) != (size_t)pcmBytes) {
            break;  // El consumidor cerro la tuberia.
        }
        fflush(stdout);

        XS_SLEEP_MS(20);
        elapsedMs += 20;

        if (durationMs > 0 && elapsedMs >= (unsigned long long)durationMs) {
            // Termina como si el dispositivo hubiera fallado.
            fprintf(stderr, "fakeffmpeg: fin de la captura simulada\n");
            fflush(stderr);
            free(pcm);
            return 3;
        }
    }

    free(pcm);
    return 0;
}
