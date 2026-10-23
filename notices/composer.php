<?php

$vendor = $argv[1] ?? 'vendor';
$title = $argv[2] ?? 'PHP-Bibliotheken';

$installed = json_decode(file_get_contents("$vendor/composer/installed.json"), true);
$dev = array_flip($installed['dev-package-names'] ?? []);

$packages = [];
foreach ($installed['packages'] ?? $installed as $package) {
    if (isset($dev[$package['name']])) {
        continue;
    }
    $packages[] = [
        'name' => $package['name'],
        'version' => ltrim($package['version'] ?? '', 'v'),
        'license' => implode(' OR ', $package['license'] ?? []) ?: 'siehe Lizenztext',
        'text' => licenseText("$vendor/{$package['name']}"),
    ];
}
usort($packages, fn (array $a, array $b) => strcasecmp($a['name'], $b['name']));

echo json_encode(['title' => $title, 'packages' => $packages], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), "\n";

function licenseText(string $dir): string
{
    foreach (is_dir($dir) ? scandir($dir) : [] as $file) {
        if (preg_match('/^(licen[cs]e|copying)/i', $file) && is_file("$dir/$file")) {
            return trim(file_get_contents("$dir/$file"));
        }
    }

    return '';
}
