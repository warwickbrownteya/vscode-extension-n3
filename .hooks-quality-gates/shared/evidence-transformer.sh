#!/bin/bash
# shared/evidence-transformer.sh
# Transform findings into QGAMS evidence format (future integration)

# Transform findings to QGAMS evidence format
# QGAMS (Quality Gates Approval & Measurement System) integration point
transform_to_qgams_evidence() {
  local findings_json="$1"
  local hook_name="$2"

  if [ -z "$findings_json" ] || [ "$findings_json" = "[]" ]; then
    echo "[]"
    return 0
  fi

  # Transform to QGAMS evidence schema:
  # {
  #   "evidence_id": "UUID",
  #   "hook": "hook_name",
  #   "findings": [...],
  #   "consensus_status": "unanimous|majority|minority|blocked",
  #   "approval_required": true|false,
  #   "approval_authority": "QA_Lead|Security_Officer|CISO",
  #   "timestamp": "ISO8601"
  # }

  jq --arg hook "$hook_name" \
    '{
      evidence_id: ("evd_" + (now | floor | tostring)),
      hook: $hook,
      findings: .,
      consensus_status: "pending",
      approval_required: true,
      approval_authority: "Security_Officer",
      timestamp: (now | todateiso8601),
      context: {
        commit_sha: (env.GIT_COMMIT // "unknown"),
        branch: (env.GIT_BRANCH // "unknown"),
        author: (env.GIT_AUTHOR // "unknown")
      }
    }' <<< "$findings_json" 2>/dev/null || echo "[]"
}

# Prepare evidence for approval workflow
prepare_approval_request() {
  local findings_json="$1"
  local hook_name="$2"
  local justification="$3"

  jq --arg hook "$hook_name" \
    --arg justification "$justification" \
    '{
      hook: $hook,
      findings: .,
      justification: $justification,
      requested_at: (now | todateiso8601),
      requested_by: (env.GIT_AUTHOR // "unknown"),
      approval_type: "check-waived"
    }' <<< "$findings_json" 2>/dev/null || echo "[]"
}
