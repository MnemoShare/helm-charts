{{/* Effective outbound deferral spool settings as JSON. dig keeps `helm upgrade --reuse-values` from a pre-spool release rendering the defaults. */}}
{{- define "mnemoshare.gatewaySpool" -}}
{{- $v := .Values.AsMap -}}
{{- $mode := dig "emailGateway" "mode" "gateway" $v -}}
{{- $on := and (dig "emailGateway" "enabled" false $v) (eq $mode "gateway") (dig "emailGateway" "spool" "enabled" true $v) -}}
{{- $s := dict "on" ($on | default false) "dir" (dig "emailGateway" "spool" "dir" "/var/spool/mnemo-gateway" $v) "persistenceEnabled" (dig "emailGateway" "spool" "persistence" "enabled" true $v) "size" (dig "emailGateway" "spool" "persistence" "size" "5Gi" $v) "storageClass" (dig "emailGateway" "spool" "persistence" "storageClass" "" $v) "accessModes" (dig "emailGateway" "spool" "persistence" "accessModes" (list "ReadWriteOnce") $v) "existingClaim" (dig "emailGateway" "spool" "persistence" "existingClaim" "" $v) -}}
{{- $_ := set $s "claim" ($s.existingClaim | default (printf "%s-gateway-spool" (include "mnemoshare.fullname" .))) -}}
{{- if $s.on -}}
{{- if ne (dig "emailGateway" "replicas" 1 $v | int) 1 -}}{{- fail "emailGateway.replicas must be exactly 1 while emailGateway.spool.enabled is true: the deferral spool is a ReadWriteOnce volume owned by one pod. Set emailGateway.spool.enabled=false to run more replicas." -}}{{- end -}}
{{- if ne $s.dir "/var/spool/mnemo-gateway" -}}{{- fail "emailGateway.spool.dir must be /var/spool/mnemo-gateway" -}}{{- end -}}
{{- if and (not $s.persistenceEnabled) (not $s.existingClaim) -}}{{- fail "emailGateway.spool requires emailGateway.spool.persistence.enabled=true or emailGateway.spool.persistence.existingClaim; set emailGateway.spool.enabled=false to run without a spool" -}}{{- end -}}
{{- if and $s.persistenceEnabled (not $s.size) -}}{{- fail "emailGateway.spool.persistence.size is required while emailGateway.spool.persistence.enabled is true" -}}{{- end -}}
{{- if not (dig "fsGroup" 0 (dig "podSecurityContext" dict $v)) -}}{{- fail "podSecurityContext.fsGroup is required while emailGateway.spool.enabled is true: the non-root gateway must be able to write the spool volume" -}}{{- end -}}
{{- end -}}
{{- toJson $s -}}
{{- end -}}
