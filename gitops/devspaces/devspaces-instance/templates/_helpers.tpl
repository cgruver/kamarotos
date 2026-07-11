{{/*
Expand the name of the chart.
*/}}
{{- define "devspaces-instance.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Determine target namespace
*/}}
{{- define "devspaces-instance.namespace" -}}
{{- if .Values.namespace }}
{{- printf "%s" .Values.namespace }}
{{- else }}
{{- printf "%s" .Release.Namespace }}
{{- end }}
{{- end }}

{{/*
ArgoCD Syncwave for CheCluster instance
*/}}
{{- define "devspaces-instance.argocd-syncwave" -}}
{{- if .Values.argocd }}
{{- if and (.Values.argocd.instance.syncwave) (.Values.argocd.enabled) -}}
argocd.argoproj.io/sync-wave: "{{ .Values.argocd.instance.syncwave }}"
{{- else }}
{{- "{}" }}
{{- end }}
{{- else }}
{{- "{}" }}
{{- end }}
{{- end }}
