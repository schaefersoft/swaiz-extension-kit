package main

import (
	"bytes"
	"debug/buildinfo"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type pkg struct {
	Name    string `json:"name"`
	Version string `json:"version"`
	License string `json:"license"`
	Text    string `json:"text"`
}

type fragment struct {
	Title    string `json:"title"`
	Packages []pkg  `json:"packages"`
}

var licenseFile = regexp.MustCompile(`(?i)^(licen[cs]e|copying)`)

func main() {
	title := flag.String("title", "Go-Module", "section title")
	withMain := flag.Bool("main", false, "also list the main module of each binary")
	flag.Parse()

	mods := map[string]string{}
	goVersion := ""
	for _, bin := range flag.Args() {
		bi, err := buildinfo.ReadFile(bin)
		if err != nil {
			fail(err)
		}
		goVersion = bi.GoVersion
		if *withMain && bi.Main.Version != "" && bi.Main.Version != "(devel)" {
			mods[bi.Main.Path] = bi.Main.Version
		}
		for _, d := range bi.Deps {
			if r := d.Replace; r != nil && r.Version != "" && r.Version != "(devel)" && !strings.HasPrefix(r.Path, ".") && !strings.HasPrefix(r.Path, "/") {
				d = r
			}
			if d.Version != "" && d.Version != "(devel)" {
				mods[d.Path] = d.Version
			}
		}
	}

	dirs, err := download(mods)
	if err != nil {
		fail(err)
	}
	packages := make([]pkg, 0, len(mods)+1)
	for path, version := range mods {
		license, text := licenseOf(dirs[path+"@"+version])
		packages = append(packages, pkg{Name: path, Version: version, License: license, Text: text})
	}
	sort.Slice(packages, func(i, j int) bool { return packages[i].Name < packages[j].Name })

	goroot, err := exec.Command("go", "env", "GOROOT").Output()
	if err != nil {
		fail(err)
	}
	stdlib, _ := os.ReadFile(filepath.Join(strings.TrimSpace(string(goroot)), "LICENSE"))
	packages = append([]pkg{{Name: "Go standard library", Version: goVersion, License: "BSD-3-Clause", Text: strings.TrimSpace(string(stdlib))}}, packages...)

	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", " ")
	if err := enc.Encode(fragment{Title: *title, Packages: packages}); err != nil {
		fail(err)
	}
}

func download(mods map[string]string) (map[string]string, error) {
	dirs := map[string]string{}
	if len(mods) == 0 {
		return dirs, nil
	}
	args := []string{"mod", "download", "-json"}
	for path, version := range mods {
		args = append(args, path+"@"+version)
	}
	cmd := exec.Command("go", args...)
	cmd.Dir = os.TempDir()
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil && len(out) == 0 {
		return nil, fmt.Errorf("go mod download: %w", err)
	}
	dec := json.NewDecoder(bytes.NewReader(out))
	for {
		var m struct{ Path, Version, Dir string }
		if err := dec.Decode(&m); errors.Is(err, io.EOF) {
			return dirs, nil
		} else if err != nil {
			return nil, err
		}
		dirs[m.Path+"@"+m.Version] = m.Dir
	}
}

func licenseOf(dir string) (string, string) {
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if e.Type().IsRegular() && licenseFile.MatchString(e.Name()) {
			raw, err := os.ReadFile(filepath.Join(dir, e.Name()))
			if err != nil {
				break
			}
			text := strings.TrimSpace(string(raw))
			return detect(text), text
		}
	}
	return "siehe Lizenztext", ""
}

func detect(t string) string {
	switch {
	case strings.Contains(t, "Apache License") && strings.Contains(t, "Version 2.0"):
		return "Apache-2.0"
	case strings.Contains(t, "Mozilla Public License"):
		return "MPL-2.0"
	case strings.Contains(t, "GNU AFFERO GENERAL PUBLIC LICENSE"):
		return "AGPL" + gnuVersion(t)
	case strings.Contains(t, "CC0 1.0") || strings.Contains(t, "CC0-1.0"):
		return "CC0-1.0"
	case strings.Contains(t, "GNU LESSER GENERAL PUBLIC LICENSE"):
		return "LGPL" + gnuVersion(t)
	case strings.Contains(t, "GNU GENERAL PUBLIC LICENSE"):
		return "GPL" + gnuVersion(t)
	case strings.Contains(t, "Permission to use, copy, modify, and"):
		return "ISC"
	case strings.Contains(t, "Permission is hereby granted, free of charge"):
		return "MIT"
	case strings.Contains(t, "Redistribution and use in source and binary forms"):
		if strings.Contains(t, "Neither the name") || strings.Contains(t, "endorse or promote") {
			return "BSD-3-Clause"
		}
		return "BSD-2-Clause"
	}
	return "siehe Lizenztext"
}

func gnuVersion(t string) string {
	for _, v := range []string{"3", "2.1", "2"} {
		if strings.Contains(t, "Version "+v+",") || strings.Contains(t, "Version "+v+" ") {
			return "-" + v
		}
	}
	return ""
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "gonotices:", err)
	os.Exit(1)
}
