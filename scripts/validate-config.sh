#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ $# -eq 0 ]]; then
  components_file="${REPO_ROOT}/config/components.json"
  models_file="${REPO_ROOT}/config/models.json"
elif [[ $# -eq 2 ]]; then
  components_file="$1"
  models_file="$2"
else
  echo "Usage: $0 [COMPONENTS_JSON MODELS_JSON]" >&2
  exit 2
fi

errors=""

check_json_syntax() {
  local label="$1"
  local file="$2"

  if [[ ! -f "$file" ]]; then
    errors+="${label}: file does not exist: ${file}"$'\n'
    return 1
  fi
  if ! jq empty "$file" >/dev/null 2>&1; then
    errors+="${label}: invalid JSON syntax in ${file}"$'\n'
    return 1
  fi
}

components_valid=true
models_valid=true
check_json_syntax "components" "$components_file" || components_valid=false
check_json_syntax "models" "$models_file" || models_valid=false

if [[ "$components_valid" == true ]]; then
  if component_errors="$(jq -r '
    def string: type == "string" and length > 0;
    def digest: string and test("^sha256:[0-9a-f]{64}$");
    def revision: string and test("^[0-9a-f]{40}$|^[0-9a-f]{64}$");
    def local_url:
      type != "string" or
      (test("^https?://(127\\.0\\.0\\.1|localhost|host\\.docker\\.internal)(:|/|$)"));
    def exposed_secret:
      . as $value |
      ($value | type == "string") and
      ($value | length > 0) and
      ($value | test("^<[^>]+>$") | not) and
      ($value | test("^(true|false)(_when_[a-z_]+)?$") | not);
    def secret_errors($root):
      [paths(scalars) as $path |
       (getpath($path)) as $value |
       ($path[-1] | tostring | ascii_downcase) as $key |
       select((($key | test("(^|_)(password|secret|token|api_key|private_key)($|_)")) and
               ($value | exposed_secret)) or
              (($value | type == "string") and
               ($value | test("gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----")))) |
       "\($root)\($path | map("[\(.|tojson)]") | join("")): catalog contains a secret-like value"];

    . as $catalog |
    ([if (.schema_version | type) != "number" or .schema_version != 1
       then "components.schema_version: expected integer 1" else empty end,
      if (.components | type) != "array" or (.components | length) == 0
       then "components.components: expected a non-empty array" else empty end] +
     if (.components | type) == "array" then
       ([.components | to_entries[] | select((.value | type) != "object") |
          "components.components[\(.key)]: expected an object"] +
        [.components | map(select(type == "object")) | group_by(.id)[] |
         select((.[0].id | string) and length > 1) |
         "components.components: duplicate id \(.[0].id | tojson)"] +
        [.components | to_entries[] | select((.value | type) == "object") | .key as $i | .value as $c |
          [if ($c.id | string | not) then "components.components[\($i)].id: expected a non-empty immutable identifier" else empty end,
           if ($c.name | string | not) then "components.components[\($i)].name: expected a non-empty string" else empty end,
           if (["native_inference_runtime", "containerized_web_application", "native_cli", "containerized_support_service", "evaluation_tool"] | index($c.type)) == null
             then "components.components[\($i)].type: unsupported component type \($c.type | tojson)" else empty end,
           if (["mvp", "deferred", "optional", "rejected"] | index($c.status)) == null
             then "components.components[\($i)].status: expected mvp, deferred, optional, or rejected" else empty end,
           if ($c.version | string | not) or ($c.version | ascii_downcase) == "latest"
             then "components.components[\($i)].version: expected an exact non-floating version" else empty end,
           if ($c.license | string | not) then "components.components[\($i)].license: expected a non-empty license" else empty end,
           if ($c.source.repository | string | not) then "components.components[\($i)].source.repository: expected a source URL" else empty end,
           if ($c.source.revision | revision | not) then "components.components[\($i)].source.revision: expected an immutable 40- or 64-hex revision" else empty end,
           if ($c.artifact | type) != "object" then "components.components[\($i)].artifact: expected an object" else empty end,
           if $c.artifact.distribution == "oci_image" and (($c.artifact.reference | type) != "string" or ($c.artifact.reference | test("@sha256:[0-9a-f]{64}$") | not))
             then "components.components[\($i)].artifact.reference: OCI images must use an immutable @sha256 digest, not a floating tag" else empty end,
           if $c.artifact.distribution == "oci_image" and ($c.artifact.index_digest | digest | not)
             then "components.components[\($i)].artifact.index_digest: expected sha256:<64 lowercase hex>" else empty end,
           if $c.artifact.distribution == "oci_image" and ($c.artifact.qualified_platform_digest | digest | not)
             then "components.components[\($i)].artifact.qualified_platform_digest: expected sha256:<64 lowercase hex>" else empty end,
           if $c.artifact.distribution != "oci_image" and (($c.artifact.sha256 | type) != "string" or ($c.artifact.sha256 | test("^[0-9a-f]{64}$") | not))
             then "components.components[\($i)].artifact.sha256: expected 64 lowercase hex characters" else empty end,
           if ($c.platform | type) != "object" then "components.components[\($i)].platform: expected an object" else empty end,
           if ($c.endpoints | type) != "object" or ($c.endpoints | length) == 0 then "components.components[\($i)].endpoints: expected a non-empty endpoint map" else empty end,
           if $c.status == "mvp" then
             ($c.endpoints | to_entries[]? |
               select((.value | type) == "string" and (.value | test("^https?://")) and (.value | local_url | not)) |
               "components.components[\($i)].endpoints.\(.key): MVP endpoint must be local, got \(.value | tojson)")
             else empty end,
           if $c.status == "mvp" then
             ($c.required_environment | to_entries[]? |
               select((.value | type) == "string" and (.value | test("^https?://")) and (.value | local_url | not)) |
               "components.components[\($i)].required_environment.\(.key): MVP endpoint default must be local, got \(.value | tojson)")
             else empty end,
           if ($c.capabilities | type) != "object" or ($c.capabilities | length) == 0 then "components.components[\($i)].capabilities: expected a non-empty capability map" else empty end,
           if ($c.decision | string | not) then "components.components[\($i)].decision: expected a decision-record path" else empty end] | .[]] | flatten)
      else [] end + secret_errors("components")) | .[]
  ' "$components_file" 2>&1)"; then
    if [[ -n "$component_errors" ]]; then
      errors+="${component_errors}"$'\n'
    fi
  else
    errors+="components: semantic validation could not process ${components_file}: ${component_errors}"$'\n'
  fi
fi

if [[ "$models_valid" == true ]]; then
  if model_errors="$(jq -r '
    def string: type == "string" and length > 0;
    def digest: string and test("^sha256:[0-9a-f]{64}$");
    def revision: string and test("^[0-9a-f]{40}$|^[0-9a-f]{64}$");
    def exposed_secret:
      . as $value |
      ($value | type == "string") and ($value | length > 0) and
      ($value | test("^<[^>]+>$") | not);
    def secret_errors($root):
      [paths(scalars) as $path |
       (getpath($path)) as $value |
       ($path[-1] | tostring | ascii_downcase) as $key |
       select((($key | test("(^|_)(password|secret|token|api_key|private_key)($|_)")) and
               ($value | exposed_secret)) or
              (($value | type == "string") and
               ($value | test("gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----")))) |
       "\($root)\($path | map("[\(.|tojson)]") | join("")): catalog contains a secret-like value"];

    . as $catalog |
    ([if (.schema_version | type) != "number" or .schema_version != 1
       then "models.schema_version: expected integer 1" else empty end,
      if (.qualified_runtime.component | string | not) then "models.qualified_runtime.component: expected a component id" else empty end,
      if (.qualified_runtime.version | string | not) then "models.qualified_runtime.version: expected an exact version" else empty end,
      if (.defaults | type) != "object" then "models.defaults: expected a role-to-alias map" else empty end,
      if (.models | type) != "array" or (.models | length) == 0 then "models.models: expected a non-empty array" else empty end,
      if (.rag.embedding.model_id | string | not) then "models.rag.embedding.model_id: expected a non-empty model id" else empty end,
      if (.rag.embedding.revision | revision | not) then "models.rag.embedding.revision: expected an immutable 40- or 64-hex revision" else empty end,
      if (.rag.embedding.license | string | not) then "models.rag.embedding.license: expected a non-empty license" else empty end,
      if (.rag.embedding.cache_path | string | not) then "models.rag.embedding.cache_path: expected a non-empty local cache location" else empty end,
      if (.rag.embedding.snapshot_tree_digest.digest | digest | not) then "models.rag.embedding.snapshot_tree_digest.digest: expected sha256:<64 lowercase hex>" else empty end,
      if (.rag.embedding.weights.sha256 | type) != "string" or (.rag.embedding.weights.sha256 | test("^[0-9a-f]{64}$") | not)
        then "models.rag.embedding.weights.sha256: expected 64 lowercase hex characters" else empty end] +
     if (.models | type) == "array" then
       ([.models | to_entries[] | select((.value | type) != "object") |
          "models.models[\(.key)]: expected an object"] +
        [.models | map(select(type == "object")) | group_by(.alias)[] |
         select((.[0].alias | string) and length > 1) |
         "models.models: duplicate alias \(.[0].alias | tojson)"] +
        [.models | to_entries[] | select((.value | type) == "object") | .key as $i | .value as $m |
          [if ($m.alias | string | not) then "models.models[\($i)].alias: expected a non-empty unique alias" else empty end,
           if ($m.tag | string | not) or ($m.tag | ascii_downcase | test("(^|:)latest$"))
             then "models.models[\($i)].tag: expected an exact non-floating Ollama tag" else empty end,
           if ($m.executable | type) != "boolean" then "models.models[\($i)].executable: expected a boolean" else empty end,
           if ($m.qualification_status | string | not) then "models.models[\($i)].qualification_status: expected a non-empty status" else empty end,
           if ($m.source | string | not) then "models.models[\($i)].source: expected a source URL" else empty end,
           if ($m.manifest_digest | digest | not) then "models.models[\($i)].manifest_digest: expected immutable sha256:<64 lowercase hex>" else empty end,
           if ($m.license | string | not) then "models.models[\($i)].license: expected a non-empty license" else empty end,
           if ($m.artifact_bytes | type) != "number" or $m.artifact_bytes <= 0 then "models.models[\($i)].artifact_bytes: expected a positive number" else empty end,
           if (($m.capabilities | type) != "object" or ($m.capabilities | length) == 0) and
              (($m.declared_capabilities | type) != "array" or ($m.declared_capabilities | length) == 0)
             then "models.models[\($i)].capabilities: expected capabilities or declared_capabilities" else empty end,
           if $m.executable and ($m.capabilities | type) == "object" and
              (["text", "code", "tools", "vision"] | any(. as $cap | ($m.capabilities[$cap] | type) != "boolean"))
             then "models.models[\($i)].capabilities: executable models require boolean text, code, tools, and vision fields" else empty end,
           if $m.executable and (($m.blobs | type) != "array" or ($m.blobs | length) == 0)
             then "models.models[\($i)].blobs: executable models require immutable blob metadata" else empty end,
           if $m.executable then
             ($m.blobs | to_entries[]? | select(.value.digest | digest | not) |
               "models.models[\($i)].blobs[\(.key)].digest: expected sha256:<64 lowercase hex>")
             else empty end,
           if ($m.executable | not) and ($m.blob_digest_set.digest | digest | not)
             then "models.models[\($i)].blob_digest_set.digest: non-executable qualified artifacts require an immutable digest set" else empty end] | .[]] | flatten)
      else [] end +
     if (.defaults | type) == "object" and (.models | type) == "array" then
       [.defaults | to_entries[] | .key as $role | .value as $alias |
        ([ $catalog.models[] | select(type == "object") | select(.alias == $alias and .executable == true) ] | length) as $matches |
        if (($alias | string | not) or $matches != 1) then
          "models.defaults.\($role): expected exactly one executable model alias, got \($alias | tojson)"
        else
          ([ $catalog.models[] | select(type == "object") | select(.alias == $alias) ][0]) as $selected |
          ({chat: "text", fast: "text", coding: "code", vision: "vision"}[$role]) as $capability |
          if $capability != null and
             (($selected.capabilities | type) != "object" or $selected.capabilities[$capability] != true)
            then "models.defaults.\($role): alias \($alias | tojson) lacks required \($capability) capability"
            else empty end
        end]
      else [] end + secret_errors("models")) | .[]
  ' "$models_file" 2>&1)"; then
    if [[ -n "$model_errors" ]]; then
      errors+="${model_errors}"$'\n'
    fi
  else
    errors+="models: semantic validation could not process ${models_file}: ${model_errors}"$'\n'
  fi
fi

if [[ -n "$errors" ]]; then
  echo "Configuration validation failed:" >&2
  printf '%s' "$errors" | sed '/^$/d; s/^/  - /' >&2
  exit 1
fi

echo "Configuration catalogs are valid."
