{{/*
Expand the name of the chart.
*/}}
{{- define "workspace-images.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "workspace-images.labels" -}}
app: {{ include "workspace-images.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}