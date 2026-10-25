// ffmpeg falso para pruebas.
//
// Se comporta como el FFmpeg real en lo unico que le importa a Xtreme Studio:
//   - escribe el MP3 codificado por *stdout* (pipe:1)
//   - escribe el PCM crudo de niveles por *stderr* (pipe:2)
//   - guarda en un archivo los argumentos con los que lo invocaron, para poder
//     verificar que la linea de comandos es la esperada
//   - sale solo cuando se cierra la entrada estandar o al recibir Ctrl+C
//
// Asi se puede probar TODO el motor de emision (arranque, envio, reconexion por
// caida de red, cambio de metadatos, apagado) sin depender de que Flutter
// compile ni de que haya un microfono.
//
// Variables de entorno:
//   FAKEFFMPEG_ARGS_FILE   archivo donde escribir los argumentos (uno por linea)
//   FAKEFFMPEG_DURATION_MS cuanto tiempo emitir si nadie lo detiene (0 = infinito)

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

static void append_args_file(int argc, char **argv) {
    const char *path = getenv("FAKEFFMPEG_ARGS_FILE");
    if (path == NULL || path[0] == '\0') return;

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

/// Escribe PCM s16le mono: una onda cuadrada de amplitud media (-6 dBFS), que
/// el vumetro debe medir. Asi se comprueba que los niveles llegan de verdad.
static void write_pcm(unsigned char *buf, int bytes, unsigned int counter) {
    int samples = bytes / 2;
    for (int i = 0; i < samples; i++) {
        short value;
        unsigned int phase = (counter + (unsigned int)i) % 100;
        if (phase < 50) {
            value = 16384;   // +0.5 de escala
        } else {
            value = -16384;
        }
        buf[i * 2] = (unsigned char)(value & 0xFF);
        buf[i * 2 + 1] = (unsigned char)((value >> 8) & 0xFF);
    }
}

int main(int argc, char **argv) {
    // Salida binaria y sin buffer: el motor en Dart debe recibir los datos ya.
#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);
    _setmode(_fileno(stderr), _O_BINARY);
#endif
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    append_args_file(argc, argv);

    // Modo diagnostico: el motor relanza FFmpeg pidiendo un instante de audio
    // (con `-t`) para capturar el motivo real de un fallo. Aqui se reproduce el
    // caso tipico: el dispositivo no existe.
    {
        const char *diag = getenv("FAKEFFMPEG_DIAGNOSE_MESSAGE");
        int esDiagnostico = 0;
        for (int i = 0; i < argc; i++) {
            if (strcmp(argv[i], "-t") == 0) esDiagnostico = 1;
        }
        if (esDiagnostico && diag != NULL && diag[0] != '\0') {
            fputs(diag, stderr);
            fputc('\n', stderr);
            fflush(stderr);
            return 1;
        }
    }

    int durationMs = 0;
    const char *dur = getenv("FAKEFFMPEG_DURATION_MS");
    if (dur != NULL && dur[0] != '\0') durationMs = atoi(dur);

    unsigned char mp3[512];
    unsigned char pcm[160];  // 80 muestras a 8 kHz = 10 ms
    unsigned int mp3Counter = 0;
    unsigned int pcmCounter = 0;
    unsigned long long elapsedMs = 0;

    // Cada 20 ms se emite un bloque de MP3 (~320 bytes, equivalente a 128 kbps)
    // y un bloque de PCM de 10 ms.
    const int mp3Bytes = 320;
    const int pcmBytes = 160;
    const unsigned int stepMs = 20;

    for (;;) {
        write_mp3(mp3, mp3Bytes, mp3Counter);
        write_pcm(pcm, pcmBytes, pcmCounter);
        mp3Counter++;
        pcmCounter += 40;

        if (fwrite(mp3, 1, mp3Bytes, stdout) != (size_t)mp3Bytes) {
            break;  // El consumidor cerro la tuberia.
        }
        fflush(stdout);

        if (fwrite(pcm, 1, pcmBytes, stderr) != (size_t)pcmBytes) {
            break;
        }
        fflush(stderr);

        XS_SLEEP_MS(stepMs);
        elapsedMs += stepMs;

        if (durationMs > 0 && elapsedMs >= (unsigned long long)durationMs) {
            // Termina como si el dispositivo hubiera fallado.
            fprintf(stderr, "fakeffmpeg: fin de la emision simulada\n");
            fflush(stderr);
            return 3;
        }
    }

    return 0;
}
