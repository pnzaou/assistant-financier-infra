{{/*
Nom de base des ressources.
*/}}
{{- define "af.nom" -}}
{{- default .Chart.Name .Values.nomComplet | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "af.nomComplet" -}}
{{- if .Values.nomComplet -}}
{{- .Values.nomComplet | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Labels communs. `app.kubernetes.io/version` porte le tag de l'image serveur :
c'est ce qui permet de savoir d'un coup d'œil quelle version tourne.
*/}}
{{- define "af.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "af.nom" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.serveur.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: assistant-financier
{{- end -}}

{{/*
Sélecteurs par composant. Volontairement réduits aux clés stables :
`selector` est immuable après création d'un Deployment, y mettre la version
rendrait toute mise à jour impossible.
*/}}
{{- define "af.selecteurs" -}}
app.kubernetes.io/name: {{ include "af.nom" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Nom du Secret applicatif : celui fourni par l'utilisateur, sinon celui du chart.
*/}}
{{- define "af.nomSecret" -}}
{{- if .Values.secrets.secretExistant -}}
{{- .Values.secrets.secretExistant -}}
{{- else -}}
{{- printf "%s-secrets" (include "af.nomComplet" .) -}}
{{- end -}}
{{- end -}}

{{- define "af.nomSecretPostgres" -}}
{{- if .Values.postgres.secretExistant -}}
{{- .Values.postgres.secretExistant -}}
{{- else -}}
{{- printf "%s-postgres" (include "af.nomComplet" .) -}}
{{- end -}}
{{- end -}}

{{- define "af.hotePostgres" -}}
{{- printf "%s-postgres" (include "af.nomComplet" .) -}}
{{- end -}}

{{/*
Contraintes d'ordonnancement, communes à tous les pods du chart.

Sur AKS, le pool applicatif est en priorité Spot et porte donc le taint
`kubernetes.azure.com/scalesetpriority=spot:NoSchedule`, tandis que le pool
système porte `CriticalAddonsOnly`. Sans tolérer le premier, aucun pod de ce
chart ne trouverait de nœud : ils resteraient tous indéfiniment en Pending.
*/}}
{{- define "af.ordonnancement" -}}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
Bloc d'environnement partagé par l'API et par le Job de migration : les deux
doivent voir exactement la même base et les mêmes clés, sinon une migration
s'appliquerait ailleurs que là où tourne l'application.
*/}}
{{- define "af.envServeur" -}}
- name: NODE_ENV
  value: {{ .Values.config.nodeEnv | quote }}
- name: PORT
  value: {{ .Values.serveur.port | quote }}
- name: CLIENT_URLS
  value: {{ .Values.config.urlsClient | quote }}
{{- if .Values.postgres.active }}
{{/*
  Postgres dans le cluster : l'URL est reconstituée à partir du mot de passe
  du Secret. La substitution $(VAR) est faite par Kubernetes lui-même, et ne
  fonctionne que si la variable référencée est déclarée AVANT dans la liste —
  d'où l'ordre ci-dessous, qui n'est pas cosmétique.
*/}}
- name: POSTGRES_MOT_DE_PASSE
  valueFrom:
    secretKeyRef:
      name: {{ include "af.nomSecretPostgres" . }}
      key: motDePasse
- name: DATABASE_URL
  value: "postgresql://{{ .Values.postgres.utilisateur }}:$(POSTGRES_MOT_DE_PASSE)@{{ include "af.hotePostgres" . }}:5432/{{ .Values.postgres.base }}?schema=public"
{{- else }}
{{/*
  Base externe (Cloud SQL). Le chart ne fabrique plus l'URL : elle est fournie
  entière dans le Secret applicatif, sous la clé `databaseUrl`. Sans ce
  branchement, les pods référenceraient un Secret Postgres qui n'existe pas et
  resteraient indéfiniment en CreateContainerConfigError.
*/}}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "af.nomSecret" . }}
      key: databaseUrl
{{- end }}
- name: JWT_PRIVATE_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "af.nomSecret" . }}
      key: jwtClePrivee
- name: JWT_PUBLIC_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "af.nomSecret" . }}
      key: jwtClePublique
- name: COOKIE_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "af.nomSecret" . }}
      key: cookieSecret
- name: RESEND_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "af.nomSecret" . }}
      key: resendApiKey
      optional: true
{{- end -}}
