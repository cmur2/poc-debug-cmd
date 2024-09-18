#!/bin/bash

if [ -z "$1" ]; then
    >&2 echo "Usage: $0 PR_NUMBER"
    exit 1
fi

PR_NUMBER="$1"
PR_HEAD_SHA=$(gh api -X GET "repos/cmur2/poc-debug-cmd/pulls/$PR_NUMBER" --jq '.head.sha')

echo "# Results for PR $PR_NUMBER"
echo ""

gh api -X GET "repos/cmur2/poc-debug-cmd/actions/runs?sha=$PR_HEAD_SHA" --jq '.workflow_runs[]' | while read -r workflow_run; do
 workflow_run_id=$(echo "$workflow_run" | jq -r '.id')
 workflow_run_attempt=$(echo "$workflow_run" | jq -r '.run_attempt')
  >&2 echo "Checking workflow run $workflow_run_id attempt $workflow_run_attempt for problems..."

  gh api -X GET "repos/cmur2/poc-debug-cmd/actions/runs/$workflow_run_id/attempts/$workflow_run_attempt/jobs?per_page=100" --jq '.jobs[] | select(.conclusion=="failure") .id' | while read -r job_id; do
    >&2 echo "Checking failed job $job_id for well known failure reasons..."

    runner_problem_annotations=$(gh api -X GET "/repos/cmur2/poc-debug-cmd/check-runs/$job_id/annotations" --jq '.[] | select(.message | contains("lost communication with the server") or contains("runner has received a shutdown signal"))')
    if echo "$runner_problem_annotations" | grep -q message; then
      runner_name=$(gh api "repos/cmur2/poc-debug-cmd/actions/jobs/$job_id" --jq '.runner_name' | tr '[:upper:]' '[:lower:]')
      if [ "$runner_name" == "" ]; then
        runner_name=$(echo "$runner_problem_annotations" | grep -oP '(?<=The self-hosted runner: )\S+')
      fi
      >&2 echo "Job $job_id got aborted due to problem with runner: $runner_name"

      echo "* [Job $job_id](https://github.com/cmur2/poc-debug-cmd/actions/runs/$workflow_run_id/job/$job_id?pr=$PR_NUMBER) got aborted due to problems with runner \`$runner_name\`:"
      echo "  * GitHub prematurely lost connection to the runner which can happen due to high job CPU load (try reducing load), network issues or hardware failures (try rerunning)."
      echo "  * Check [resource usage for runner \`$runner_name\`](https://dashboard.int.camunda.com/d/000000019/pods?orgId=1&var-namespace=camunda&var-pod=$runner_name&var-container=All&from=now-7d&to=now) and [Kubernetes logs for runner \`$runner_name\`](https://console.cloud.google.com/logs/query;query=resource.type%3D%22k8s_cluster%22%0Aresource.labels.project_id%3D%22ci-30-162810%22%0Aresource.labels.location%3D%22europe-west1%22%0Aresource.labels.cluster_name%3D%22camunda-ci%22%20$runner_name;duration=P7D?project=ci-30-162810)."
    fi

    timeout_annotations=$(gh api -X GET "/repos/cmur2/poc-debug-cmd/check-runs/$job_id/annotations" --jq '.[] | select(.message | contains("has exceeded the maximum execution time"))')
    if echo "$timeout_annotations" | grep -q message; then
      runner_name=$(gh api "repos/cmur2/poc-debug-cmd/actions/jobs/$job_id" --jq '.runner_name' | tr '[:upper:]' '[:lower:]')

      >&2 echo "Job $job_id got cancelled due to timeout."

      echo "* [Job $job_id](https://github.com/cmur2/poc-debug-cmd/actions/runs/$workflow_run_id/job/$job_id?pr=$PR_NUMBER) got cancelled due to timeout:"
      echo "  * Try rerunning if that is the first time, otherwise try speeding up the job."
      if [[ $runner_name == camunda-* ]]; then
        echo "  * Check [resource usage for runner \`$runner_name\`](https://dashboard.int.camunda.com/d/000000019/pods?orgId=1&var-namespace=camunda&var-pod=$runner_name&var-container=All&from=now-7d&to=now)."
      fi
    fi
  done
done
