/* Xtreme Studio — interacciones mínimas, sin dependencias. */
(() => {
  const SITE = {
    repo: 'envidia1972-create/xtreme_studio',
    youtube: 'https://www.youtube.com/@XtremeStudio',
  };

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));

  const formatBytes = (bytes) => {
    if (!bytes || bytes < 1) return '';
    const mb = bytes / 1_000_000;
    return `${mb.toFixed(1).replace('.', ',')} MB`;
  };

  const formatDate = (value) => {
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return '';
    return new Intl.DateTimeFormat('es-PA', {
      day: 'numeric', month: 'short', year: 'numeric',
    }).format(date);
  };

  // Enlaces de YouTube configurables en un solo lugar.
  $$('[data-youtube]').forEach((link) => {
    if (SITE.youtube) link.href = SITE.youtube;
  });

  // Header con borde al hacer scroll.
  const header = $('.site-header');
  const onScroll = () => header?.classList.toggle('scrolled', window.scrollY > 8);
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  // Navegación móvil.
  const toggle = $('.nav-toggle');
  const nav = $('#nav-menu');
  toggle?.addEventListener('click', () => {
    const open = nav?.classList.toggle('open') ?? false;
    toggle.setAttribute('aria-expanded', String(open));
    toggle.setAttribute('aria-label', open ? 'Cerrar menú' : 'Abrir menú');
  });
  $$('#nav-menu a').forEach((link) => link.addEventListener('click', () => {
    nav?.classList.remove('open');
    toggle?.setAttribute('aria-expanded', 'false');
  }));

  // Año actual.
  const year = $('#year');
  if (year) year.textContent = String(new Date().getFullYear());

  // Copiar checksum.
  const copy = $('#copy-checksum');
  copy?.addEventListener('click', async () => {
    const text = $('#release-checksum')?.textContent?.trim() || '';
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
      copy.textContent = 'Copiado';
      setTimeout(() => { copy.textContent = 'Copiar'; }, 1600);
    } catch {
      // Fallback para navegadores sin permiso de clipboard.
      const area = document.createElement('textarea');
      area.value = text;
      area.style.position = 'fixed';
      area.style.opacity = '0';
      document.body.appendChild(area);
      area.select();
      document.execCommand('copy');
      area.remove();
      copy.textContent = 'Copiado';
      setTimeout(() => { copy.textContent = 'Copiar'; }, 1600);
    }
  });

  // Última release desde la API pública de GitHub.
  const releaseStatus = $('#release-status');
  const downloadButton = $('#download-button');
  const versionLabel = $('#release-version');
  const sizeLabel = $('#release-size');
  const checksumLabel = $('#release-checksum');
  const releaseLink = $('#release-link');

  const setStatus = (text) => {
    if (releaseStatus) releaseStatus.textContent = text;
  };

  async function fetchChecksum(release, asset) {
    if (asset.digest?.startsWith('sha256:')) {
      return asset.digest.slice('sha256:'.length).toLowerCase();
    }
    const checksumAsset = (release.assets || []).find((item) =>
      /checksum|sha256/i.test(item.name));
    if (!checksumAsset) return '';
    const response = await fetch(checksumAsset.browser_download_url, {
      headers: { Accept: 'text/plain' },
    });
    if (!response.ok) return '';
    const text = await response.text();
    const line = text.split(/\r?\n/).find((item) => item.includes(asset.name));
    if (!line) return '';
    const hash = line.trim().split(/\s+/)[0];
    return /^[a-f0-9]{64}$/i.test(hash) ? hash.toLowerCase() : '';
  }

  async function loadRelease() {
    try {
      const response = await fetch(
        `https://api.github.com/repos/${SITE.repo}/releases/latest`,
        { headers: { Accept: 'application/vnd.github+json' } },
      );
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const release = await response.json();
      const assets = Array.isArray(release.assets) ? release.assets : [];
      const windows = assets.find((asset) =>
        /windows/i.test(asset.name) && /\.zip$/i.test(asset.name));

      if (versionLabel) versionLabel.textContent = release.tag_name || '';
      if (releaseLink) releaseLink.href = release.html_url || releaseLink.href;

      const linux = assets.find((asset) =>
        /linux/i.test(asset.name) && /(\.tar\.gz|\.tgz)$/i.test(asset.name));
      const linuxButton = $('#linux-download');
      const linuxMeta = $('#linux-release-meta');
      if (linux && linuxButton) {
        linuxButton.href = linux.browser_download_url;
        if (linuxMeta) {
          const linuxSize = formatBytes(linux.size);
          linuxMeta.textContent = `${release.tag_name}${linuxSize ? ` · ${linuxSize}` : ''} · actualización automática`;
        }
      } else if (linuxMeta) {
        linuxMeta.textContent = 'Todavía no hay un paquete Linux en la última release. Podés compilar desde el código.';
      }

      if (!windows) {
        setStatus('La última release no incluye un paquete para Windows. Abrí la release para ver las opciones.');
        return;
      }

      if (downloadButton) downloadButton.href = windows.browser_download_url;
      if (sizeLabel) sizeLabel.textContent = formatBytes(windows.size) || 'tamaño variable';
      const date = formatDate(release.published_at);
      setStatus(`Versión publicada${date ? ` el ${date}` : ''}. Comprobada automáticamente desde GitHub.`);
      if (releaseLink) {
        releaseLink.hidden = false;
        releaseLink.href = release.html_url;
      }

      const hash = await fetchChecksum(release, windows);
      if (hash && checksumLabel) {
        checksumLabel.textContent = hash;
      } else if (checksumLabel) {
        checksumLabel.textContent = 'Checksum no disponible en esta release';
      }
    } catch (error) {
      setStatus('No se pudo consultar GitHub en este momento. Usá el enlace de la release para descargar.');
      console.warn('Xtreme Studio: no se pudo consultar la release', error);
    }
  }
  loadRelease();

  // Formulario de comentarios: prepara un issue en GitHub, sin backend.
  const form = $('#feedback-form');
  form?.addEventListener('submit', (event) => {
    event.preventDefault();
    const type = $('#feedback-type')?.value || 'Comentario';
    const name = $('#feedback-name')?.value?.trim() || '';
    const message = $('#feedback-message')?.value?.trim() || '';
    const note = $('#feedback-note');
    if (!message || message.length < 10) {
      if (note) note.textContent = 'Escribí un mensaje de al menos 10 caracteres.';
      return;
    }
    const title = `[${type}] ${message.split('\n')[0].slice(0, 90)}`;
    const body = [
      `**Tipo:** ${type}`,
      name ? `**Nombre:** ${name}` : '',
      '',
      message,
      '',
      '---',
      'Enviado desde la web de Xtreme Studio.',
    ].filter(Boolean).join('\n');
    const url = `https://github.com/${SITE.repo}/issues/new?title=${encodeURIComponent(title)}&body=${encodeURIComponent(body)}`;
    if (note) note.textContent = 'Abriendo GitHub Issues…';
    window.open(url, '_blank', 'noopener');
  });
})();
