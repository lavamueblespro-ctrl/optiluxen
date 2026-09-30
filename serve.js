/* ============================================================
   Optiluxen - servidor local (sin dependencias)
   Uso:  node serve.js
   Luego abre:  http://localhost:3000
   ============================================================ */
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 3000;
const ROOT = __dirname;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'text/javascript; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg':  'image/svg+xml',
  '.png':  'image/png',
  '.jpg':  'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico':  'image/x-icon',
  '.pdf':  'application/pdf',
  '.csv':  'text/csv; charset=utf-8',
  '.sql':  'text/plain; charset=utf-8',
  '.md':   'text/plain; charset=utf-8'
};

// Cabeceras de seguridad (equivalente a _headers de Netlify)
const SEC_HEADERS = {
  'X-Frame-Options': 'DENY',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'Cross-Origin-Opener-Policy': 'same-origin',
  'X-Permitted-Cross-Domain-Policies': 'none',
  'Content-Security-Policy': "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' "
    + "https://cdnjs.cloudflare.com https://cdn.sheetjs.com https://cdn.jsdelivr.net; "
    + "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
    + "font-src 'self' data: https://fonts.gstatic.com; "
    + "img-src 'self' data: blob: https://*.supabase.co; "
    + "media-src 'self' blob: data:; "
    + "connect-src 'self' https://*.supabase.co wss://*.supabase.co; "
    + "frame-src 'self' blob:; worker-src 'self' blob:; "
    + "object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
};

const server = http.createServer((req, res) => {
  try {
    let urlPath = decodeURIComponent(req.url.split('?')[0]);
    if (urlPath === '/') urlPath = '/index.html';

    // evitar salirse de la carpeta
    // (se compara con el separador final: "/app" no debe permitir "/app-otra")
    const filePath = path.join(ROOT, path.normalize(urlPath));
    const rootSep = ROOT.endsWith(path.sep) ? ROOT : ROOT + path.sep;
    if (!filePath.startsWith(rootSep)) {
      res.writeHead(403); return res.end('403');
    }

    if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      return res.end('404 - no encontrado: ' + urlPath);
    }

    const ext = path.extname(filePath).toLowerCase();
    // mismas cabeceras de seguridad que en Netlify (ver _headers)
    res.writeHead(200, Object.assign({ 'Content-Type': MIME[ext] || 'application/octet-stream' }, SEC_HEADERS));
    fs.createReadStream(filePath).pipe(res);
  } catch (e) {
    res.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('400 - peticion invalida');
  }
});

server.listen(PORT, () => {
  console.log('');
  console.log('  Optiluxen corriendo en  http://localhost:' + PORT);
  console.log('  (pulse Ctrl+C para detener)');
  console.log('');
});
