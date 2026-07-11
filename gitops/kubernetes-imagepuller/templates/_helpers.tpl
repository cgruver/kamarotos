{{/*
Expand the name of the chart.
*/}}
{{- define "kubernetes-imagepuller.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "kubernetes-imagepuller.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kubernetes-imagepuller.labels" -}}
helm.sh/chart: {{ include "kubernetes-imagepuller.chart" . }}
{{ include "kubernetes-imagepuller.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kubernetes-imagepuller.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kubernetes-imagepuller.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
