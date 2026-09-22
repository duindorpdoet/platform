if (!process.env.GITHUB_TOKEN || !process.env.GITHUB_REPOSITORY || !process.env.GITHUB_SHA) {
  throw new Error("GitHub deployment context is incomplete.");
}

const headers = {
  Accept: "application/vnd.github+json",
  Authorization: `Bearer ${process.env.GITHUB_TOKEN}`,
  "X-GitHub-Api-Version": "2022-11-28",
};
const api = `https://api.github.com/repos/${process.env.GITHUB_REPOSITORY}`;
// A deployment job can succeed before the separate mailbox job fails.
// Require the entire staging workflow, including real receipt, on this SHA.
const runsResponse = await fetch(`${api}/actions/workflows/deploy-staging.yml/runs?head_sha=${process.env.GITHUB_SHA}&branch=staging&status=success&per_page=100`, { headers });
if (!runsResponse.ok) throw new Error(`Could not read staging workflow results (${runsResponse.status}).`);
const runs = await runsResponse.json();
if (!runs.workflow_runs?.some((run) => run.head_sha === process.env.GITHUB_SHA && run.head_branch === "staging" && run.conclusion === "success")) {
  throw new Error("Production promotion requires the entire staging workflow, including real mailbox acceptance, to succeed on this exact Git commit.");
}

const deploymentsResponse = await fetch(`${api}/deployments?sha=${process.env.GITHUB_SHA}&environment=staging&per_page=10`, { headers });
if (!deploymentsResponse.ok) throw new Error(`Could not read staging deployments (${deploymentsResponse.status}).`);
const deployments = await deploymentsResponse.json();

let approved = false;
for (const deployment of deployments) {
  const statusesResponse = await fetch(`${api}/deployments/${deployment.id}/statuses?per_page=10`, { headers });
  if (!statusesResponse.ok) throw new Error(`Could not read staging deployment status (${statusesResponse.status}).`);
  const statuses = await statusesResponse.json();
  if (statuses.some((status) => status.state === "success")) {
    approved = true;
    break;
  }
}

if (!approved) throw new Error("Production promotion requires a successful staging deployment of this exact Git commit.");
console.log(`Exact revision ${process.env.GITHUB_SHA} has a successful staging deployment.`);
