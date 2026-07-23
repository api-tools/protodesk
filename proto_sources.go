package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/bufbuild/protocompile"
	"github.com/bufbuild/protocompile/linker"
	"google.golang.org/protobuf/reflect/protoregistry"
)

const protoCompileTimeout = 10 * time.Second

func findProtoFilesInFolder(folder string) ([]string, error) {
	root, err := filepath.Abs(folder)
	if err != nil {
		return nil, err
	}
	var files []string
	if err := filepath.WalkDir(root, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			return nil
		}
		if strings.EqualFold(filepath.Ext(path), ".proto") {
			files = append(files, normalizePath(path))
		}
		return nil
	}); err != nil {
		return nil, err
	}
	sort.Strings(files)
	return files, nil
}

func validateProtoSources(ctx context.Context, request ValidateProtoSourcesRequest) ValidateProtoSourcesResponse {
	_, fileCount, errors := compileProtoSources(ctx, request)
	return ValidateProtoSourcesResponse{
		Valid:     len(errors) == 0,
		FileCount: fileCount,
		Errors:    errors,
	}
}

func compileProtoSources(ctx context.Context, request ValidateProtoSourcesRequest) (linker.Files, int, []string) {
	index, errors := buildProtoSourceIndex(request)
	if len(errors) > 0 {
		return nil, len(index.files), errors
	}
	if len(index.targets) == 0 {
		return linker.Files{}, 0, nil
	}

	compiler := protocompile.Compiler{
		Resolver: protocompile.WithStandardImports(protocompile.ResolverFunc(index.findFileByPath)),
	}
	compileCtx, cancel := context.WithTimeout(ctx, protoCompileTimeout)
	defer cancel()
	files, err := compiler.Compile(compileCtx, index.targets...)
	if err != nil {
		return nil, len(index.files), []string{err.Error()}
	}
	return files, len(index.files), nil
}

type protoSourceIndex struct {
	files       map[string]string
	importRoots []string
	targets     []string
}

func buildProtoSourceIndex(request ValidateProtoSourcesRequest) (protoSourceIndex, []string) {
	index := protoSourceIndex{
		files: map[string]string{},
	}
	var errors []string

	for _, folderPath := range normalizePathList(request.ProtoFolders) {
		info, err := os.Stat(folderPath)
		if err != nil {
			errors = append(errors, fmt.Sprintf("proto folder %q cannot be read: %v", folderPath, err))
			continue
		}
		if !info.IsDir() {
			errors = append(errors, fmt.Sprintf("proto folder %q is not a directory", folderPath))
			continue
		}

		index.importRoots = append(index.importRoots, folderPath)
		files, err := findProtoFilesInFolder(folderPath)
		if err != nil {
			errors = append(errors, fmt.Sprintf("proto folder %q cannot be scanned: %v", folderPath, err))
			continue
		}
		for _, filePath := range files {
			target, err := filepath.Rel(folderPath, filePath)
			if err != nil {
				errors = append(errors, fmt.Sprintf("proto file %q cannot be indexed: %v", filePath, err))
				continue
			}
			index.addTarget(filepath.ToSlash(target), filePath, &errors)
		}
	}

	for _, filePath := range normalizePathList(request.ProtoFiles) {
		info, err := os.Stat(filePath)
		if err != nil {
			errors = append(errors, fmt.Sprintf("proto file %q cannot be read: %v", filePath, err))
			continue
		}
		if info.IsDir() {
			errors = append(errors, fmt.Sprintf("proto file %q is a directory", filePath))
			continue
		}
		if !strings.EqualFold(filepath.Ext(filePath), ".proto") {
			errors = append(errors, fmt.Sprintf("proto file %q is not a .proto file", filePath))
			continue
		}

		index.importRoots = append(index.importRoots, filepath.Dir(filePath))
		index.addTarget(filepath.ToSlash(filepath.Base(filePath)), filePath, &errors)
	}

	index.importRoots = uniqueStrings(index.importRoots)
	sort.Strings(index.targets)
	return index, errors
}

func (index *protoSourceIndex) addTarget(target string, filePath string, errors *[]string) {
	cleanTarget := pathClean(target)
	cleanPath := normalizePath(filePath)
	if existing, exists := index.files[cleanTarget]; exists && existing != cleanPath {
		*errors = append(*errors, fmt.Sprintf("duplicate proto import path %q maps to both %q and %q", cleanTarget, existing, cleanPath))
		return
	}
	if _, exists := index.files[cleanTarget]; !exists {
		index.targets = append(index.targets, cleanTarget)
	}
	index.files[cleanTarget] = cleanPath
}

func (index protoSourceIndex) findFileByPath(importPath string) (protocompile.SearchResult, error) {
	cleanImportPath, safe := safeProtoImportPath(importPath)
	if !safe {
		return protocompile.SearchResult{}, protoregistry.NotFound
	}
	if filePath, ok := index.files[cleanImportPath]; ok {
		return sourceResult(filePath)
	}
	for _, root := range index.importRoots {
		candidate := normalizePath(filepath.Join(root, filepath.FromSlash(cleanImportPath)))
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && pathWithinRoot(root, candidate) {
			return sourceResult(candidate)
		}
	}
	return protocompile.SearchResult{}, protoregistry.NotFound
}

func safeProtoImportPath(importPath string) (string, bool) {
	trimmed := strings.TrimSpace(importPath)
	if trimmed == "" || filepath.IsAbs(trimmed) || filepath.VolumeName(trimmed) != "" {
		return "", false
	}
	clean := pathClean(trimmed)
	if clean == ".." || strings.HasPrefix(clean, "../") {
		return "", false
	}
	return clean, true
}

func pathWithinRoot(root string, candidate string) bool {
	resolvedRoot, err := filepath.EvalSymlinks(normalizePath(root))
	if err != nil {
		return false
	}
	resolvedCandidate, err := filepath.EvalSymlinks(normalizePath(candidate))
	if err != nil {
		return false
	}
	relative, err := filepath.Rel(resolvedRoot, resolvedCandidate)
	if err != nil {
		return false
	}
	return relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func sourceResult(path string) (protocompile.SearchResult, error) {
	file, err := os.Open(path)
	if err != nil {
		return protocompile.SearchResult{}, err
	}
	return protocompile.SearchResult{Source: readCloser{Reader: file, Closer: file}}, nil
}

type readCloser struct {
	io.Reader
	io.Closer
}

func normalizePath(path string) string {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return ""
	}
	absolute, err := filepath.Abs(trimmed)
	if err != nil {
		return filepath.Clean(trimmed)
	}
	return filepath.Clean(absolute)
}

func normalizePathList(paths []string) []string {
	seen := map[string]struct{}{}
	var out []string
	for _, path := range paths {
		cleanPath := normalizePath(path)
		if cleanPath == "" {
			continue
		}
		if _, exists := seen[cleanPath]; exists {
			continue
		}
		seen[cleanPath] = struct{}{}
		out = append(out, cleanPath)
	}
	sort.Strings(out)
	return out
}

func uniqueStrings(values []string) []string {
	seen := map[string]struct{}{}
	var out []string
	for _, value := range values {
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	return out
}

func pathClean(path string) string {
	return strings.TrimPrefix(filepath.ToSlash(filepath.Clean(filepath.FromSlash(path))), "./")
}
