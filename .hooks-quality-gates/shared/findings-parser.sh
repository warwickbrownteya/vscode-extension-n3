#!/bin/bash
# shared/findings-parser.sh
# Normalize tool outputs into standardized JSON format

# Parse findings from tool output into standardized format
# Usage: parse_findings <output_file> <hook_name> <tool_name>
parse_findings() {
  local output_file="$1"
  local hook_name="$2"
  local tool_name="$3"

  if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
    echo "[]"
    return 0
  fi

  case "$tool_name" in
    "truffleHop")
      parse_trufflehop "$output_file" "$hook_name"
      ;;
    "semgrep")
      parse_semgrep "$output_file" "$hook_name"
      ;;
    "npm")
      parse_npm "$output_file" "$hook_name"
      ;;
    "checkov")
      parse_checkov "$output_file" "$hook_name"
      ;;
    *)
      # Default: attempt JSON parsing
      jq '.' "$output_file" 2>/dev/null || echo "[]"
      ;;
  esac
}

# Parse TruffleHop JSON output
parse_trufflehop() {
  local file="$1"
  local hook_name="$2"

  jq --arg hook "$hook_name" --arg tool "truffleHop" \
    '[.[] | {
      id: .id,
      hook: $hook,
      tool: $tool,
      type: .type,
      severity: "critical",
      file: .file_path,
      line: .line_number,
      message: .secret_type,
      timestamp: (now | todateiso8601)
    }]' "$file" 2>/dev/null || echo "[]"
}

# Parse Semgrep JSON output
parse_semgrep() {
  local file="$1"
  local hook_name="$2"

  jq --arg hook "$hook_name" --arg tool "semgrep" \
    '[.results[]? | {
      id: .check_id,
      hook: $hook,
      tool: $tool,
      type: "sast",
      severity: .extra.severity // "medium",
      file: .path,
      line: .start.line,
      message: .extra.message,
      timestamp: (now | todateiso8601)
    }]' "$file" 2>/dev/null || echo "[]"
}

# Parse npm audit JSON output
parse_npm() {
  local file="$1"
  local hook_name="$2"

  jq --arg hook "$hook_name" --arg tool "npm" \
    '[.vulnerabilities[]? | {
      id: .id,
      hook: $hook,
      tool: $tool,
      type: "sca",
      severity: .severity,
      file: "package.json",
      line: 0,
      message: .title,
      timestamp: (now | todateiso8601)
    }]' "$file" 2>/dev/null || echo "[]"
}

# Parse Checkov JSON output
parse_checkov() {
  local file="$1"
  local hook_name="$2"

  jq --arg hook "$hook_name" --arg tool "checkov" \
    '[.failed_checks[]? | {
      id: .check_id,
      hook: $hook,
      tool: $tool,
      type: "iac",
      severity: .check.severity // "medium",
      file: .file_path,
      line: .file_line_range[0],
      message: .check.name,
      timestamp: (now | todateiso8601)
    }]' "$file" 2>/dev/null || echo "[]"
}
