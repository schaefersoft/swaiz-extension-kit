import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const title = process.argv[2] ?? 'JavaScript-Bibliotheken';
const lock = JSON.parse(readFileSync('package-lock.json', 'utf8'));

const licenseText = (dir) => {
    if (!existsSync(dir)) return '';
    const file = readdirSync(dir).find((f) => /^(licen[cs]e|copying)/i.test(f) && statSync(join(dir, f)).isFile());
    return file ? readFileSync(join(dir, file), 'utf8').trim() : '';
};

const seen = new Map();
for (const [path, entry] of Object.entries(lock.packages ?? {})) {
    if (!path || entry.dev || entry.devOptional || entry.link || entry.os || entry.cpu) continue;
    const name = entry.name ?? path.slice(path.lastIndexOf('node_modules/') + 'node_modules/'.length);
    const license = typeof entry.license === 'string' ? entry.license : entry.license?.type;
    seen.set(`${name}@${entry.version}`, {
        name,
        version: entry.version ?? '',
        license: license || 'siehe Lizenztext',
        text: licenseText(path),
    });
}

const packages = [...seen.values()].sort((a, b) => a.name.localeCompare(b.name));
process.stdout.write(JSON.stringify({ title, packages }, null, 1) + '\n');
