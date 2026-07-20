{{- define "flow.labels" -}}
app.kubernetes.io/part-of: flow
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
