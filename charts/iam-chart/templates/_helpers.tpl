{{/* 
Define helper templates and common functions here.
*/}}

{{/*
Return the namespace for Keycloak.
*/}}
{{- define "iam-chart.namespace" -}}
{{- .Values.namespace.keycloak }}
{{- end -}}

{{/*
Generate full name for resources.
*/}}
{{- define "iam-chart.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "iam-chart.labels" -}}
app.kubernetes.io/name: {{ include "iam-chart.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
