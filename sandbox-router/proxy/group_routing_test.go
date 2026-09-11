// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package proxy

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"k8s.io/apimachinery/pkg/types"

	"sigs.k8s.io/agent-sandbox/sandbox-router/cache"
	"sigs.k8s.io/agent-sandbox/sandbox-router/config"
)

func TestParseSandboxGroupHeaders(t *testing.T) {
	h := make(http.Header)
	h.Set(HeaderSandboxGroup, "my-agent-group")
	h.Set(HeaderSandboxNamespace, "test-ns")
	h.Set(HeaderSandboxPort, "8080")

	group, namespace, port, perr := ParseSandboxGroupHeaders(h)
	if perr != nil {
		t.Fatalf("ParseSandboxGroupHeaders: %v", perr)
	}
	if group != "my-agent-group" || namespace != "test-ns" || port != 8080 {
		t.Fatalf("unexpected parsed values: group=%q namespace=%q port=%d", group, namespace, port)
	}
}

func TestParseSandboxGroupHeadersRejectsExplicitSandbox(t *testing.T) {
	h := make(http.Header)
	h.Set(HeaderSandboxGroup, "my-agent-group")
	h.Set(HeaderSandboxID, "sandbox-a")
	if _, _, _, perr := ParseSandboxGroupHeaders(h); perr == nil || perr.Status != http.StatusBadRequest {
		t.Fatalf("expected 400 for group + explicit sandbox, got %#v", perr)
	}
}

func TestResolveTargetGroupReturnsConcreteSandbox(t *testing.T) {
	cfg := config.Defaults()
	lookup := &fakeLookup{
		entries: map[types.UID]cache.Entry{
			"uid-a": {PodIP: "10.0.0.10", SandboxName: "sandbox-a", Namespace: "test-ns"},
		},
		groups: map[string][]types.UID{"test-ns/my-agent-group": []types.UID{"uid-a"}},
	}
	h := &Handler{cfg: &cfg, cache: lookup}
	r := httptest.NewRequest(http.MethodPost, "http://router/invoke-agent", nil)
	r.Header.Set(HeaderSandboxGroup, "my-agent-group")
	r.Header.Set(HeaderSandboxNamespace, "test-ns")
	r.Header.Set(HeaderSandboxPort, "8080")

	upstreamPath, upstreamRawPath := r.URL.Path, ""
	pathRouted := false
	target, perr := h.resolveTarget(r, &upstreamPath, &upstreamRawPath, &pathRouted)
	if perr != nil {
		t.Fatalf("resolveTarget: %v", perr)
	}
	if target.ID != "sandbox-a" || target.UID != "uid-a" || target.Namespace != "test-ns" || target.Port != 8080 {
		t.Fatalf("unexpected target: %+v", target)
	}
}

func TestResolveTargetGroupNoReadyMember(t *testing.T) {
	cfg := config.Defaults()
	h := &Handler{cfg: &cfg, cache: &fakeLookup{entries: map[types.UID]cache.Entry{}}}
	r := httptest.NewRequest(http.MethodPost, "http://router/invoke-agent", nil)
	r.Header.Set(HeaderSandboxGroup, "my-agent-group")
	r.Header.Set(HeaderSandboxNamespace, "test-ns")

	upstreamPath, upstreamRawPath := r.URL.Path, ""
	pathRouted := false
	_, perr := h.resolveTarget(r, &upstreamPath, &upstreamRawPath, &pathRouted)
	if perr == nil || perr.Status != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %#v", perr)
	}
}
