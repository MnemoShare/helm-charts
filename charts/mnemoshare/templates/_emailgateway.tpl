{{/* Resolve the one emailgateway profile selected by the exact environment emitted by this chart. */}}
{{- define "mnemoshare.emailGatewayV3" -}}
{{- $raw := required "vendored tests/contracts/deployment/v3/contract.json is required" (.Files.Get "tests/contracts/deployment/v3/contract.json") -}}
{{- $contract := fromJson $raw -}}
{{- if ne $contract.provenance.schema "mnemoshare.deployment-contract.v3" -}}{{- fail "vendored deployment contract is not v3" -}}{{- end -}}
{{- $found := dict -}}
{{- range $contract.executables -}}{{- if eq .id "emailgateway" -}}{{- $_ := set $found "executable" . -}}{{- end -}}{{- end -}}
{{- if not (hasKey $found "executable") -}}{{- fail "vendored deployment contract v3 has no emailgateway executable" -}}{{- end -}}
{{- $executable := get $found "executable" -}}
{{- $env := dict "GATEWAY_MODE" .Values.emailGateway.mode -}}
{{- $relayMode := eq .Values.emailGateway.mode "relay" -}}
{{- $inboundMode := eq .Values.emailGateway.mode "inbound-relay" -}}
{{- $dbSet := or .Values.emailGateway.relay.db.uri .Values.emailGateway.relay.db.existingSecret -}}
{{- $adminSet := or .Values.emailGateway.relay.adminKey .Values.emailGateway.relay.existingAdminKeySecret -}}
{{- $spoolKeySet := or .Values.emailGateway.relay.spoolSharedKey .Values.emailGateway.relay.existingSpoolKeySecret -}}
{{- if and $relayMode $dbSet -}}{{- $_ := set $env "RELAY_DB_URI" "configured" -}}{{- end -}}
{{- if and (or $relayMode $inboundMode) $adminSet -}}{{- $_ := set $env "RELAY_ADMIN_KEY" "configured" -}}{{- end -}}
{{- if and (or $relayMode $inboundMode) $spoolKeySet -}}{{- $_ := set $env "RELAY_SPOOL_SHARED_KEY" "configured" -}}{{- end -}}
{{- if $relayMode -}}{{- $_ := set $env "RELAY_SMTP_AUTH_REQUIRED" (ternary "true" "false" .Values.emailGateway.smtpAuthRequired) -}}{{- end -}}
{{- $matches := list -}}
{{- range $profile := $executable.profiles -}}
  {{- $profileMatches := false -}}
  {{- range $case := $profile.selection -}}
    {{- $all := true -}}
    {{- range $condition := $case.all -}}
      {{- $present := and (hasKey $env $condition.name) (ne (get $env $condition.name) "") -}}
      {{- if eq $condition.operator "equals" -}}{{- $all = and $all $present (eq (get $env $condition.name) $condition.value) -}}
      {{- else if eq $condition.operator "set" -}}{{- $all = and $all $present -}}
      {{- else if eq $condition.operator "unset" -}}{{- $all = and $all (not $present) -}}
      {{- else -}}{{- fail (printf "unsupported deployment-contract v3 selection operator %s" $condition.operator) -}}{{- end -}}
    {{- end -}}
    {{- $profileMatches = or $profileMatches $all -}}
  {{- end -}}
  {{- if $profileMatches -}}{{- $matches = append $matches $profile.id -}}{{- end -}}
{{- end -}}
{{- if ne (len $matches) 1 -}}{{- fail (printf "emailGateway configuration must select exactly one deployment-contract v3 profile, selected %d" (len $matches)) -}}{{- end -}}
{{- $profileID := first $matches -}}
{{- $profile := dict -}}
{{- range $executable.profiles -}}{{- if eq .id $profileID -}}{{- $profile = . -}}{{- end -}}{{- end -}}
{{- if ne $profile.persistence "none" -}}{{- fail (printf "emailgateway profile %s must remain primary persistence=none" $profileID) -}}{{- end -}}
{{- toJson (dict "executable" $executable "profile" $profile "environment" $env) -}}
{{- end -}}

{{/* Contract-controlled names cannot be redefined through the legacy escape hatch. */}}
{{- define "mnemoshare.validateEmailGatewayExtraEnvV3" -}}
{{- $facts := include "mnemoshare.emailGatewayV3" . | fromJson -}}
{{- $reserved := dict "SMTP_AUTH_REQUIRED" true -}}
{{- $_ := set $reserved $facts.executable.profile_selector true -}}
{{- range $facts.executable.profiles -}}
  {{- range .environment -}}{{- $_ := set $reserved . true -}}{{- end -}}
  {{- range .selection -}}{{- range .all -}}{{- $_ := set $reserved .name true -}}{{- end -}}{{- end -}}
  {{- range .external_universes -}}{{- range .environment -}}{{- $_ := set $reserved . true -}}{{- end -}}{{- end -}}
  {{- range .durable_resources -}}{{- if .path_environment -}}{{- $_ := set $reserved .path_environment true -}}{{- end -}}{{- end -}}
{{- end -}}
{{- range .Values.emailGateway.extraEnv -}}
  {{- if hasKey $reserved .name -}}{{- fail (printf "emailGateway.extraEnv may not override deployment-contract v3 environment %s" .name) -}}{{- end -}}
{{- end -}}
{{- end -}}
