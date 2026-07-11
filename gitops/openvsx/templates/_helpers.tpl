{{/*
Expand the name of the chart.
*/}}
{{- define "openvsx.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "openvsx.labels" -}}
app: {{ include "openvsx.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
