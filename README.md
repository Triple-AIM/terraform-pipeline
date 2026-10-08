# terraform-pipeline

This is a Terraform pipeline for GitHub Actions. It runs `terraform plan` on
pull requests and `terraform apply` on merge. It is built around one question:
**if someone can push a branch, what can they do with your credentials?**

To adopt it, see [Getting started](#getting-started).

## The problem

Most teams run `terraform plan` on every pull request. This is useful, but it
is also the weakest point in most pipelines. A plan runs code from the branch,
and it runs that code next to a credential.

**The branch's Terraform code can read the credential.** Terraform code can
read files. On Linux, one of those files is `/proc/self/environ`. It holds all
of the Terraform process's environment variables, and that is where
credentials usually are. So this one line, added to any branch, prints the
plan credential:

```hcl
output "x" { value = filebase64("/proc/self/environ") }
```

This works in most Terraform pipelines. It does not matter whether the
credential is an OIDC token or an API key, or whether it came from a secret
store. If Terraform can see it, so can the branch's code.

This is not a new discovery. Security researchers have written about it, for
example in Snyk's
[GitFlops](https://labs.snyk.io/resources/gitflops-dangers-of-terraform-automation-platforms/).
Several vendors say so in their own documentation. HashiCorp writes that HCP
Terraform
"[cannot prevent malicious Terraform configuration from exfiltrating sensitive data during plan operations](https://developer.hashicorp.com/terraform/cloud-docs/architectural-details/security-model)".
env0 writes that
"[we do not prevent any malicious 3rd party code execution from reaching this sensitive data](https://docs.envzero.com/guides/overview/security-overview)".
What is missing is a defense.

**The branch can send the credential somewhere else.** A provider's settings
decide which server it talks to. A branch can point a provider at a server it
controls. The provider then sends its credential there.

**On GitHub Actions, the branch usually controls the workflow too.** When a
pull request comes from a branch in the same repository, GitHub normally runs
the workflow file from that branch. So the branch can add a step. That step
can use any credential the plan job can get.

**Some providers have no read-only credential.** Snowflake has no read-only
role that can complete a plan. The GitHub provider has the same problem. Other
providers only offer long-lived API keys, with no OIDC support. For these
providers, the usual advice to "give plans a read-only credential" cannot be
followed.

Put together, this means that anyone who can push a branch can often take the
plan credential. Sometimes that credential is an administrator. Usually nobody
chose this. It happens by default.

The risk is not only a dishonest engineer. It also includes a stolen account,
a leaked token, a compromised dependency, and bots or AI coding agents that
can push to the repository.

## What this pipeline does differently

Two things in this pipeline are not offered by any other Terraform tool we
checked:

- **Terraform runs in a sandbox.** The branch's Terraform code cannot read the
  credentials, because it cannot open the files that hold them. See
  [Terraform runs in a sandbox](#terraform-runs-in-a-sandbox).
- **Provider settings are checked before a plan gets credentials.** A branch
  cannot point a provider at a different server and still be planned. See
  [Provider settings are checked before the plan runs](#provider-settings-are-checked-before-the-plan-runs).

It also does the things a careful pipeline should already do:

- Plans run from your default branch's workflow, so a branch cannot add steps.
- Plans and applies use different credentials.
- Only providers you have approved can be installed.
- Applies use the exact plan that was reviewed.

None of these needs a server, and no third party holds your credentials.

We checked nine other tools in October 2026: HCP Terraform, Spacelift,
Scalr, env0, Atlantis, Terrateam, Digger, tfaction and dflook's actions. For
the open-source ones, we read the code that runs Terraform. For the others, we
read their documentation. None of them stops Terraform code from reading the
credentials. Each one passes credentials to Terraform as environment
variables, as files Terraform can open, or both. Some isolate each run in its
own container or virtual machine. That keeps runs apart from each other. It
does not stop a run's code from reading its own credentials. None of them
checks where providers will send credentials before the plan runs. Where they
offer policy checks, you write the policies, and most run after the plan.

## What has been tested

Each claim below is checked by a step in the
[self-test](.github/workflows/self-test.yml). The step's name starts with
"Claim:" and repeats the claim, so a failing check says which claim stopped
being true. The self-test runs on every pull request and every merge. It also
runs every week with the latest Terraform. So a change in Terraform, GitHub's
runners or the actions shows up even when this repository has not changed.

- Terraform code cannot read its own environment, the home directory, or
  files the sandbox does not grant. This includes reading its environment
  through a link in the workspace.
- The sandbox example in
  [Getting started](#9-open-a-pull-request) shows no warning in the
  sandbox. Outside it, the example shows its error message.
- Programs that Terraform starts do not get the runner's own variables, such
  as the token that requests OIDC tokens.
- Only providers on the list can be installed.
- Terraform's working directory is outside the checkout.
- The pipeline will not run under the usual pull_request trigger.
- The pipeline will not run if a plan or apply environment allows other
  branches.
- The pipeline will not run if the modules environment allows other
  branches.
- The pipeline runs when its environments allow only the default branch.
- A run stops if its commit is no longer the latest on the default branch.
- The pipeline does not use an approval environment that does not require a
  reviewer.
- Workflow commands in Terraform output are not acted on.
- A branch's own workflow cannot use the plan environment.
- The settings check gives the right answer in every case. The cases include
  a redirected endpoint, a provider hidden in a module, a provider renamed to
  slip past the list of safe settings, a backend run by a
  `terraform_remote_state` data source, an override file, and a file that
  cannot be read.
- A plan stops if its modules differ from the ones the settings check
  compared.
- The settings check can install a private module.
- A private module's token is not written into Terraform's working files.
- The pipeline will not run with a mistake in its config file.
- A secret or variable that is not set stops the job, and says which.
- A variable's value is not hidden in the logs.
- A root is found by its backend or cloud block, in any file.
- A lock file made on another platform works.
- The pipeline stops if a lock file would change in any way but gaining this
  platform's hashes.
- The pipeline shows the OIDC subject for each environment.
- Runs of the pipeline in the same group wait for each other.

The self-test also plans its own fixtures through the pipeline, and applies
them after a merge. That shows providers still work in the sandbox. It also shows that an
environment's API key reaches the credentials action only in that
environment's jobs. One fixture uses a module from a private repository. So
its jobs show that the token from a GitHub App works.

Before the sandbox existed, a probe on a GitHub-hosted runner showed what
Terraform code could read. It could read its own environment, including the
credentials. It could also read the home directory, the runner's temporary
files, and files outside its root. In the sandbox, it could read none of
them.

Some things have not been tested yet:

- a pull request from a real fork
- calling the pipeline from a repository in another organization. A
  repository in the same organization calls it today.

## Principles

Each principle follows from the one before.

1. **A plan needs a credential that can read sensitive data.** For some
   providers, that credential can also make changes. This comes from the
   provider. You cannot fix it by adjusting permissions.

2. **So credentials should only reach code that the branch cannot change.**
   The workflow that runs the plan must be out of the branch's control. Plans
   and applies must also use different credentials. That way, a plan cannot do
   what only an apply should.

3. **Every credential is tied to a GitHub environment.** Each job runs in an
   environment, and GitHub decides which workflows may use it. For providers
   that accept OIDC, GitHub gives the job a signed token that names its
   environment, and the provider checks it. For providers that only take API
   keys, the key is stored as a secret of the environment. GitHub only gives it
   to jobs that run in that environment.

4. **Everything depends on protecting the default branch.** In this pipeline,
   only workflows on your default branch can use the plan and apply
   environments. So your credentials are only as safe as the rules on who can
   change your default branch. It also matters who can push branches at all.

5. **The branch's Terraform code runs next to the credential.** During a
   plan, Terraform runs the branch's code. The same process holds the
   credential, and the code can read files. So the pipeline runs Terraform in
   a sandbox that stops it reading the credential. The pipeline also checks
   where the branch's providers will send the credential. Neither of these is
   perfect. The sandbox relies on the kernel. The check relies on reading the
   code the way Terraform does. And nothing can stop a plan from printing what
   it is allowed to read.

6. **So also limit the damage if an attack succeeds.** Give each credential
   the least access it needs. Split your Terraform into smaller parts so that
   no single credential covers everything. Use short-lived credentials where
   you can. Rotate long-lived keys. Keep audit logs.

## How it works

### Plans run from your default branch's workflow

The pipeline plans pull requests using GitHub's `pull_request_target` trigger.
With this trigger, GitHub always runs the workflow file from your default
branch, not from the pull request. A branch can edit its workflow files, but
those edits do not run until they are merged.

The job then checks out the pull request's Terraform code and plans it.

A re-run keeps the commit its run started with. So a re-run of an old run
would use that commit's workflow, pipeline and config. Every job that holds
credentials first checks that the run's commit is still the latest on your
default branch. If it is not, the job stops. To plan a pull request again,
push to it, or close and reopen it. A pull request into any other branch
stops here too.

### Only pull requests from your own repository are planned

GitHub also runs `pull_request_target` for pull requests from forks, and gives
those runs access to secrets. GitHub's approval settings for fork pull
requests do not apply to this trigger.

So the pipeline's first job starts with this check:

```yaml
if: >-
  !github.event.pull_request ||
  github.event.pull_request.head.repo.id == github.event.repository.id
```

GitHub checks this before the job starts. If the pull request comes from a
fork, the job is skipped. No runner starts, no token is issued, and no code
from the fork is checked out. A fork cannot remove the check, because the
workflow file always comes from your default branch.

This means the only people who can trigger a plan are people who can already
push branches to your repository.

### Plan and apply use separate environments

Plan and apply run as separate jobs. Each uses its own GitHub environment, and
each environment has its own credentials. Both environments only allow your
default branch. There can also be a third environment, for approved plans. It
is described in
[Provider settings are checked before the plan runs](#provider-settings-are-checked-before-the-plan-runs).

A plan job triggered by `pull_request_target` counts as your default branch,
so it is allowed. A branch that adds its own workflow and names one of these
environments is turned away, because that workflow runs as the branch.

Everything depends on these branch rules, so the pipeline checks them at the
start of every run. If the plan or apply environment allows any branch other
than your default branch, the run stops. It also stops if it was started by
the usual `pull_request` trigger, because then the branch controls the
workflow.

Your cloud accounts and providers trust GitHub's standard OIDC subject for
each environment, for example `repo:ORG/REPO:environment:terraform-plan`. You
do not need to change the repository's OIDC subject settings. Other workflows
in your repository that use OIDC are not affected.

If your repository uses GitHub's immutable subjects, the subject includes
numeric IDs for the owner and the repository, for example
`repo:ORG@1234/REPO@5678:environment:terraform-plan`. Newer repositories use
this format automatically. You do not have to work out which one yours uses.
The pipeline's Config job shows each environment's exact subject.

### Terraform runs in a sandbox

The pipeline runs Terraform in a sandbox. This stops the branch's code from
reading the credentials, as described in [The problem](#the-problem).

The sandbox uses Landlock, a Linux feature that lets a program give up access
to files. It also covers every provider that Terraform starts.

Inside the sandbox, Terraform can use:

- the workspace
- its own working files
- the system files that every program needs

It cannot open anything else. In particular, it cannot open:

- `/proc`, where its environment variables are
- the home directory
- the runner's temporary files, where GitHub keeps the variables that steps
  export

Terraform also does not get the runner's own variables, whose names start
with `ACTIONS_`. One of them is the token that requests OIDC tokens. A backend
or provider that a branch configures could send it anywhere. So get OIDC
credentials in your credentials action, before Terraform runs.

**Do not allow a provider that can run programs**, such as
`hashicorp/external`. The sandbox stops Terraform from opening files. But a
program that a provider starts inherits Terraform's environment, and the
credentials are there. It does not need to open any file to read them. So
with such a provider on the list, a branch can read every credential the plan
has.

Some kernels do not support Landlock. On those, the pipeline will not run
Terraform at all. GitHub's hosted Ubuntu runners do support it.

### API keys are kept out of reach

Some providers do not accept OIDC. For those, you store an API key as a secret
of each environment. The plan environment gets a key for planning. The apply
environment gets a key for applying.

GitHub only gives an environment's secrets to jobs that run in that
environment. Only your default branch can use these environments. So a branch
cannot reach the keys, for the same reason it cannot reach the OIDC tokens.

Your config file names each key, and the environment variable to put it in.
The pipeline exports it there. The provider can read it. Terraform code
cannot, because of the sandbox. GitHub hides the key's value if it ever
appears in a log.

The config cannot put a key in a Terraform variable, such as
`TF_VAR_api_key`. Terraform code can read any Terraform variable, so the key
would not be protected.

For this to work, the workflow that calls the pipeline must pass
`secrets: inherit`. Without it, GitHub gives the pipeline no secrets at all,
not even the environment's. This has a cost. It also passes the pipeline all
of your repository's and organization's other secrets. The pipeline only
exports the ones your config names. It hands the rest only to your
credentials action, if you have one, which comes from your default branch.
But keep secrets that Terraform does not need out of the repository where
you can.

Credentials must be passed as environment variables, not files. The provider
cannot read a file outside the sandbox. Terraform code can read a file inside
it.

You can also keep keys in an outside secret store, such as Vault or AWS
Secrets Manager. Your credentials action would sign in to the store with the
job's OIDC token and fetch the key. This is not needed to keep branches away
from the keys. Environment secrets already do that, and a store would rely on
the same environment rules. But a store can add things environment secrets do
not have:

- a log of every time a key is fetched
- one place to rotate a key that many repositories use
- keys that the store creates for each run and that expire soon after

### Only providers you have approved can be installed

You list the allowed providers in the config file. The pipeline turns that
list into Terraform's CLI configuration. Terraform will refuse to install
anything else, even if a module asks for it.

The pipeline reads the config file from your default branch, so the list
comes from there too. A branch can edit its own copy, but the pipeline
ignores it. So a pull request can only use a provider that is already on the
list on your default branch.

This means adding a provider works in one of two ways. You can add it to the
list and use it in the same pull request. That pull request is planned only
after it is merged. Or, if you want it planned first, add the provider to the
list in one pull request. Then use it in a second one.

Provider versions come from the pull request's lock file. So a pull request
that upgrades a provider is planned like any other. This is safe for two
reasons. The allowed list controls which providers can be installed. And the
registry's signatures prove that each download is genuine.

### Provider settings are checked before the plan runs

A provider's settings decide where it sends its credentials, as described in
[The problem](#the-problem). The sandbox cannot stop this. Backends work the
same way.

So the pipeline checks these settings before a plan gets any credentials. The
check runs in a separate job that has no plan or apply credentials. It works like
this:

1. It reads every provider and backend block the root uses. This includes
   blocks in modules. A `terraform_remote_state` data source counts as a
   backend block, because it runs a backend with the settings in its
   `config`. That includes one inside a `check` block. That data source is
   built into Terraform, so the provider list cannot stop it.
2. It sets aside any settings you have listed as safe, such as `region`.
3. It compares what is left with the blocks on your default branch. Blocks in
   any root count.

A block passes if what is left matches a block on your default branch. It
also passes if nothing is left. So a pull request can still be planned if it
changes a region, adds an alias, or adds a new root like an existing one.

Only list a setting as safe if no value of it can change where credentials
go. Any other setting that uses an expression, such as a variable, never
passes. Its value could change without its text changing.

A file with a block type the check does not know never passes. A new kind
of block could hold a provider, a backend or a data source.

An override file, such as `providers_override.tf`, never passes if it has a
provider, `terraform` or remote state block. Terraform merges an override
file's blocks into other blocks. Two blocks that each match your default
branch could merge into one that matches nothing there.

The plan job installs the modules again. Before it plans, it checks that
they are exactly the ones the settings check compared. Otherwise a module
whose source can change, such as a git tag, could pass the check and then
change.

The check reads your code with the same HCL library that Terraform uses. It
counts a value as fixed only if that library can work it out with no
variables and no functions.

If a block does not pass, the pull request is not planned until it is merged.
This includes a pull request that starts using a new provider, because nothing
on the default branch matches it yet. The pull request still gets a comment
explaining why, and it can still be merged.

You can avoid this wait by naming an approval environment. The pipeline then
plans those pull requests there, after a reviewer approves. It only uses the
approval environment if it is set up safely. It must:

- require a reviewer
- stop people from approving their own runs
- allow only your default branch

If it does not, the pipeline ignores it.

Plans in the approval environment need the same credentials as normal plans.
So give it its own copies of the plan environment's secrets. And make your
providers trust its OIDC subject, as well as the plan environment's.

### Private modules

A module in a private GitHub repository needs a token to fetch. The pipeline
creates one from a GitHub App that you name in the config file:

```yaml
private-modules:
  client-id: Iv23liEXAMPLE
  private-key-secret: MODULES_APP_KEY
```

The App belongs to the organization that owns the modules, and is installed
there:

- Give the App read access to contents, and nothing else.
- Install it with "Only select repositories", and select the module
  repositories.
- Store its private key as a secret, with the name you gave, in each
  environment that installs modules. That is every environment the config
  names.

Each job creates its own token. The token can only read, and it expires
after an hour. It covers every repository that the App's installation
selects. So adding a module repository is one change, in one place. Consumers
do not list their modules anywhere. Terraform fetches modules with git,
inside the sandbox. So the pipeline gives git the token through an
environment variable, not a file.

Git sends the token only to the owner's repositories on github.com, such as
`https://github.com/ORG/`. Write the owner in a module's source exactly as
GitHub shows it, because git compares the text.

#### Modules from another organization

The modules may belong to another organization than yours. Their owner then
creates an App for you, installs it on their own organization, and gives you
its private key. Your App never needs to be installed on your organization.
Name the owner in your config:

```yaml
private-modules:
  owner: MODULE-ORG
  client-id: Iv23liEXAMPLE
  private-key-secret: MODULE_ORG_APP_KEY
```

The owner should create one App for each organization that consumes its
modules. Then each App's installation selects only what that consumer may
read. And the owner can revoke one consumer by deleting its App, without
affecting the others.

Handing over a private key is the cost. Rotating it needs both
organizations. If that becomes a burden, a token exchange such as
[octo-sts](https://github.com/octo-sts/app) avoids the key. The module
repository names which consumers may read it, and each consumer trades its
OIDC token for a read token. But it puts a service in the middle.

Some rules follow from how this works:

- Write the module's source with `https`, such as
  `git::https://github.com/ORG/MODULES.git?ref=COMMIT`. An `ssh` source will
  not work. SSH reads its key from a file outside the sandbox, so it cannot
  reach it.
- So a deploy key will not work either, because it is an SSH key.
- The pipeline creates a token for one owner. For modules from a second
  owner, or from another git host, your credentials action can set git's
  `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_n` and `GIT_CONFIG_VALUE_n` itself.
  The pipeline adds its setting after yours. But the settings check does not
  run your credentials action. So a root that uses such a module does not
  pass the check.
- The same is true of a module from a private Terraform registry. Plans and
  applies can install it, with a `TF_TOKEN_` variable from
  `environment-variables`. The settings check cannot yet.

Hiding this token matters less than hiding the others. Once a module is
fetched, Terraform code can read all of it and print it. That can include
the module repository's history, which git usually fetches with it. So a
token that can only read the module repositories gives a branch little that
it could not get anyway. What the token adds is time: it keeps working after
the run ends. That is why the pipeline creates a new one in each job, and
why it expires so soon.

The settings check installs modules too. It runs in a job of its own, which
has no plan or apply credentials. So the config must also name a modules
environment. For a pull request, the pipeline runs the check in that
environment, which only needs the App's private key. Like the plan and apply
environments, it must allow only your default branch, and the pipeline
checks this. Do not require a reviewer for it, because the check runs for
every pull request.

It has to be an environment because of who can read a repository secret. A
branch can add a workflow of its own that reads one. It cannot read an
environment's secrets, because the environment does not allow its branch.

### Code from the pull request is only used as Terraform code

`pull_request_target` has caused serious security incidents. They are
described in [Why pull_request_target](#why-pull_request_target). In every
case, a workflow ran something from the pull request other than what it
meant to, or gave the run more access than it needed.

The pipeline follows these rules in its own code, so you do not have to:

- It checks out the exact commit from the pull request event, not the branch
  name. The branch cannot change between the check and the checkout.
- It checks out that code into its own directory and does not keep git
  credentials.
- It runs Terraform, and anything Terraform starts, in a sandbox.
- It runs nothing from the checkout except Terraform. No scripts, no local
  actions and no tool settings from the pull request.
- It keeps the Terraform CLI configuration outside the checkout.
- It keeps Terraform's working directory outside the checkout. So a branch
  cannot slip in provider binaries of its own.
- It never puts pull request details, such as the title or branch name,
  directly into shell commands.
- Its jobs ask for the smallest possible `GITHUB_TOKEN` permissions. A
  workflow you call can only reduce the permissions your workflow grants, so
  this limit always applies.
- It never writes to the Actions cache from a pull request run.
- It tells the runner not to act on workflow commands in Terraform's output.
  The branch decides what Terraform prints. Without this, a line such as
  `::add-mask::` in that output would be obeyed.

### Apply uses a saved plan

On merge, the pipeline plans your default branch, saves the plan to a file,
and applies that exact file. If anything changes between the plan and the
apply, Terraform refuses to apply it.

Each merge plans every root, not only the ones it changed. When merges queue
up, GitHub cancels a run that is still waiting once a newer one arrives. The
newer run then has to apply the cancelled run's changes too. Planning a root
that did not change only costs a refresh.

### Third-party code is pinned

Every action the pipeline uses is pinned to an exact commit. Every container
image is pinned to an exact digest. Nobody can change them without you
noticing.

## What it costs

These protections are not free. Before you adopt the pipeline, check that you
can accept these trade-offs:

- **Linux runners only.** The sandbox needs Landlock. GitHub's hosted Ubuntu
  runners have it. macOS and Windows runners do not.
- **The pipeline receives all your secrets.** The calling workflow must pass
  `secrets: inherit`, or environment secrets cannot reach the pipeline. See
  [API keys are kept out of reach](#api-keys-are-kept-out-of-reach).
- **Some pull requests wait.** A pull request that changes a provider setting
  you have not listed as safe is planned only after an approval, or after it
  is merged. So is one that starts using a new provider.
- **Adding a provider takes two pull requests** if you want it planned before
  merge. The first adds it to the list. The second uses it.
- **Credentials must come from environment variables.** A provider that only
  reads credentials from a file will not work in the sandbox.
- **Pull requests from forks are never planned.**
- **Each pull request takes a little longer.** The settings check installs
  the modules of every root on your default branch, to compare against.
- **Each merge plans every root.** See
  [Apply uses a saved plan](#apply-uses-a-saved-plan).

## Getting started

These steps adopt the pipeline in a repository that already has Terraform.
Each step says what to do, and how to tell that it worked. The reasons for
each step are in the sections above.

### 1. Check that it fits

Read [What it costs](#what-it-costs) and
[When not to use this](#when-not-to-use-this). In short, you need:

- GitHub's hosted Ubuntu runners, or Linux runners whose kernel supports
  Landlock.
- Branch rules on environments. For a private repository, this needs GitHub
  Pro, Team or Enterprise.
- Providers that take credentials from OIDC or from environment variables.
- While this repository is private, a repository in the same organization.
  This repository's Actions access setting must also allow yours. See
  [Pinning the pipeline](#pinning-the-pipeline).

If your repository is public, also allow `pull_request_target` in its
workflow event policy. From 2026-11-02, GitHub blocks this trigger by
default in public repositories.

### 2. Lay out your roots

A root is a directory whose configuration has a `backend` or `cloud` block,
in any of its files. That is also what Terraform means by a root, because it
ignores those blocks in a module. The pipeline finds the roots in your
repository, or under `root-directory` if you set it. You do not list them
anywhere.

If a `.tf` file cannot be read, the pipeline stops and names the file. It
does not guess whether that directory is a root.

Commit each root's lock file, `.terraform.lock.hcl`, as `terraform init`
makes it. You can make it on any platform, such as a Mac. You do not need
`terraform providers lock`.

The lock file decides which providers are installed, and at which versions.
The pipeline installs nothing else. It checks each download against the lock
file's hashes. The registry signs these hashes for every platform, and
`terraform init` records them all.

Terraform also records one hash of the installed files. It records this one
only for the platform it runs on. Every command after `terraform init` checks
it. So the pipeline adds it for its own platform, in its own copy of the lock
file. If the lock file would change in any other way, the job stops. The
pipeline never commits a lock file.

### 3. Create the environments

| Environment | Allowed branches | Reviewer | Holds |
|---|---|---|---|
| `terraform-plan` | Only the default branch | No | Plan credentials |
| `terraform-apply` | Only the default branch | Not needed | Apply credentials |
| A modules environment, if you use [private modules](#private-modules) | Only the default branch | No | The App's private key |
| An approval environment, if you want one | Only the default branch | Required, with self-review prevented | Copies of the plan credentials |

You can choose other names, and set them in the config file.

An environment with these names may already exist for another pipeline. If
so, wait until step 8 to restrict its branches. Restricting it now would
stop that pipeline from planning pull requests.

### 4. Make your providers trust the environments

Each environment holds everything about its own phase. The pipeline never
tells your code whether it is planning or applying. The environment decides.

- **For a provider that takes OIDC,** trust the environment's subject, such
  as `repo:ORG@1234/REPO@5678:environment:terraform-plan`. Store anything
  that differs between plan and apply, such as a role's ARN, as a variable
  of each environment.
- **For a provider that takes an API key,** store the key as a secret of the
  environment. Give the plan environment a key for planning, and the apply
  environment a key for applying. Use the same secret name in both. See
  [API keys are kept out of reach](#api-keys-are-kept-out-of-reach).

Give the plan credentials as little access as the provider allows.

You do not have to work out the subjects. The pipeline's Config job shows
each environment's exact subject, in its log and in the run's summary. So
you can set up the trust after the first run, and copy them from there.

The example above is GitHub's immutable form. It includes numeric IDs for
the owner and the repository, so a repository that is deleted and created
again under the same name cannot use your trust. Newer repositories use it
automatically. If yours does not, consider turning it on before you write
any trust. Some policy scanners flag the immutable form in an AWS trust
policy, Checkov's CKV_AWS_393 for one. You may need to skip that check.

### 5. Write the config file

Create `.github/terraform-pipeline/config.yml`:

```yaml
terraform-version: "1.16.1"

# The providers Terraform may install. It refuses any other. Each one's
# `safe-settings` are the settings a pull request may change and still be
# planned. Only list one if no value of it can change where the provider
# sends its credentials.
providers:
  hashicorp/aws:
    safe-settings: [region, default_tags]
  datadog/datadog:

# Settings of a backend that a pull request may change, in the same way.
backends:
  s3:
    safe-settings: [key]

# Environment variables to export, by name. Each value comes from a secret,
# or from a variable of the environment.
environment-variables:
  DD_API_KEY: DATADOG_API_KEY
  DD_APP_KEY: DATADOG_APP_KEY
  DD_HOST: { variable: DATADOG_HOST }
```

These are all the settings:

| Setting | What it is for | Default |
|---|---|---|
| `terraform-version` | The Terraform version to install. Put it in quotes. | Required |
| `providers` | A map from each provider Terraform may install to its `safe-settings`. | Required |
| `backends` | A map from a backend's type to its `safe-settings`. | None |
| `root-directory` | Where to look for roots. | The whole repository |
| `shared-paths` | Paths that, when changed, plan every root. `.` is the repository's top directory, so it plans every root on every change. | None |
| `environments` | The names of the `plan`, `apply`, `modules` and `approval` environments. | `terraform-plan` and `terraform-apply` |
| `environment-variables` | A map from an environment variable's name to a secret's name, or to `{ variable: NAME }`. | None |
| `private-modules` | The GitHub App for [private modules](#private-modules), and the organization that owns the modules. | None. The owner defaults to your organization. |
| `checkov`, `checkov-config` | Whether to scan with Checkov, and the config for roots that have none of their own. | No scan |

The pipeline reads this file from your default branch, never from a pull
request. It checks the file before anything else runs. It stops at an
unknown setting, a value of the wrong type, or a value exported as a
Terraform variable, and it reports every mistake at once. A Terraform
variable is refused because Terraform code can read it.

When a job starts, every secret and variable that `environment-variables`
names must be set in its environment. If one is missing, the job stops and
says which.

Use a variable for a value that differs between plan and apply but is not
secret, such as a user name or an account ID. GitHub hides a secret's value
everywhere it appears in the logs. So a user name stored as a secret would
also be hidden in plan output. A variable's value is not hidden.

### 6. Write a credentials action, if you need one

You need one only for credentials that the config file cannot export. Most
often, that is a sign-in through OIDC. Create
`.github/terraform-pipeline/credentials/action.yml`. The pipeline runs it
from your default branch, in each plan and apply job, after exporting the
config's environment variables. It receives three inputs:

- `root`: the root's path, if its credentials differ from the others'.
- `secrets`: the job's secrets as JSON, including the environment's.
- `vars`: the job's variables as JSON, including the environment's.

For example, AWS through OIDC:

```yaml
name: 'Credentials'

inputs:
  root:
    required: true
  secrets:
    required: true
  vars:
    required: true

runs:
  using: composite
  steps:
  - uses: aws-actions/configure-aws-credentials@COMMIT
    with:
      role-to-assume: ${{ fromJSON(inputs.vars).AWS_ROLE_ARN }}
      aws-region: us-east-1
```

The action must leave credentials in environment variables, not files. This
AWS action already does.

### 7. Write the workflow that calls the pipeline

Create `.github/workflows/terraform.yml`. It is the same in every
repository:

```yaml
name: 'Terraform'

on:
  pull_request_target:
    branches: [ "main" ]
  push:
    branches: [ "main" ]

permissions: {}

jobs:
  terraform:
    uses: Triple-AIM/terraform-pipeline/.github/workflows/terraform.yml@COMMIT
    # Without this, environment secrets cannot reach the pipeline.
    secrets: inherit
    # A called workflow cannot have more than this. The pipeline needs
    # `actions: read` to check your environments' rules.
    permissions:
      actions: read
      contents: read
      id-token: write
      pull-requests: write
```

Replace `COMMIT` with a full commit hash from this repository's default
branch. See [Pinning the pipeline](#pinning-the-pipeline).

The pipeline makes runs on your default branch wait for each other, so two
merges never apply at once. You do not need a `concurrency` block for this.

### 8. Merge it

The pull request that adds these files is not planned. Under
`pull_request_target`, GitHub runs the workflow from your default branch,
and the default branch does not have it yet. The config file is not checked
until then either.

The merge plans and applies every root. So before you merge:

- Check that each root's plan shows no changes, or only changes you want.
- Turn off your old pipeline's applies in the same pull request. Otherwise
  both pipelines apply.
- Restrict the plan and apply environments to the default branch, if you
  have not yet. The run checks this first, and stops if they allow any other
  branch.

To check that it worked, look at the run on your default branch. It shows a
Config job and a Roots job, then a Plan job and an Apply job for each root.
If the config file has a mistake, the Config job fails and says what it
is.

### 9. Open a pull request

Change something in one root. The pipeline plans only the roots that the
pull request touches, unless it touches a shared path. It comments the plan
on the pull request.

To see the sandbox at work, add this to a root in a pull request:

```hcl
locals {
  sandbox_probe_own_file    = "${path.module}/main.tf"
  sandbox_probe_environment = "/proc/self/environ"
}

check "sandbox" {
  assert {
    condition     = can(file(local.sandbox_probe_own_file))
    error_message = "Terraform code cannot read its own configuration, so this probe proves nothing."
  }
  assert {
    condition     = !can(filebase64(local.sandbox_probe_environment))
    error_message = "Terraform code can read its own environment."
  }
}
```

Put it in the root's `main.tf`, or change the first path to the file you
put it in. The first check is a control. If Terraform could read nothing at
all, the second check would pass without showing anything.

If the sandbox holds, the plan shows no warning. If it does not, the plan
shows the error message. In both cases, nothing from the file is printed.
Close the pull request afterwards.

### 10. Lock it down

- Protect your default branch with a ruleset. Require pull requests. Block
  force-pushes and deletion.
- Require the check named `Terraform`. It passes only when every plan
  passes, even if no root changed. In your pull requests it shows as
  `terraform / Terraform`, after the name of your calling job.
- Make sure a person has emergency access to every provider. If an apply
  breaks the pipeline's own access, someone will need to fix it by hand.

## Why pull_request_target

`pull_request_target` has a bad reputation, and it has earned it. Security
scanners such as zizmor and CodeQL flag it by default. This section explains
why this pipeline uses it anyway.

### The incidents

- **SpotBugs, reviewdog and tj-actions (2024 to 2025).** A workflow ran a
  build script from a pull request, with a maintainer's token. That led to
  secrets from more than 23,000 repositories being exposed.
  ([Unit 42](https://unit42.paloaltonetworks.com/github-actions-supply-chain-attack/))
- **Ultralytics (2024).** A branch name was put into a shell command, and ran
  as code. It poisoned the Actions cache, and a later release published a
  cryptominer.
  ([analysis](https://blog.yossarian.net/2024/12/06/zizmor-ultralytics-injection))
- **Nx "s1ngularity" (2025).** A pull request title was put into a shell
  command. That led to the theft of an npm publishing token.
  ([postmortem](https://nx.dev/blog/s1ngularity-postmortem))
- **hackerbot-claw (2026).** An automated attacker ran code in at least six
  repositories. In one, it loaded a local action from the pull request.
  ([StepSecurity](https://www.stepsecurity.io/blog/hackerbot-claw-github-actions-exploitation))

In each case, the workflow did one or more of these things:

- ran something from the pull request, such as a build script or a local
  action
- put pull request details directly into a shell command
- gave the run a broad token or a long-lived personal access token
- let the run write to a cache that later, more trusted runs used

The pipeline does none of these. See
[Code from the pull request is only used as Terraform code](#code-from-the-pull-request-is-only-used-as-terraform-code).

GitHub has also made the trigger safer. It now always uses the default
branch's workflow
([changelog](https://github.blog/changelog/2025-11-07-actions-pull_request_target-and-environment-branch-protections-changes/)).
`actions/checkout` refuses to check out a fork's code under it
([changelog](https://github.blog/changelog/2026-06-18-safer-pull_request_target-defaults-for-github-actions-checkout/)).
And its runs cannot write to the Actions cache
([changelog](https://github.blog/changelog/2026-06-26-read-only-actions-cache-for-untrusted-triggers/)).

### Why not keep the usual trigger?

The usual `pull_request` trigger runs the workflow from the branch. To stop a
branch from using the plan credential, you then have to prove which workflow
is running. GitHub can do this by adding `job_workflow_ref` to the OIDC
subject. But that setting applies to the whole repository. It changes the
subject for every workflow that uses OIDC, not only Terraform. And for
providers that match the subject exactly, such as Snowflake and Azure, every
workflow file then needs its own trust entry. It is not GitHub's default, and
it is not where most users are going.

`pull_request_target` gets the same result using GitHub's standard subject.
The price is that the pipeline has to follow the rules above without fail.
Those rules live in the pipeline's code, where they can be reviewed and
tested once, rather than in every user's setup.

## Pinning the pipeline

Your credentials trust an environment, not a version of this pipeline. So you
can upgrade the pipeline without changing any trust. The only question is who
controls which version runs.

- **Pin to a commit.** Only you decide when the version changes. The
  pipeline loads its own actions from the same commit, so they are pinned
  too. Tools like Renovate can open pull requests to upgrade it. This is the
  recommended option.

  Take the commit from this repository's own history, such as a release tag
  or the default branch. GitHub also accepts a commit that exists only in a
  fork of this repository, under this repository's name. So a commit copied
  from somewhere else could run someone else's code.
- **Pin to a tag.** Whoever can move tags in this repository decides what runs
  with your credentials. If this repository were compromised, everyone who
  pins to a tag would be affected at once. That is how the `tj-actions`
  attack spread.
- **Vendor a copy.** Copy the workflow, and the actions in
  `.github/actions/`, into your own repository. Nothing outside your
  repository runs with your credentials. But you copy in changes yourself,
  and your copy can drift from this one. Use this if you cannot call this
  repository, or cannot rely on it staying available.

Whichever you choose, a pull request that changes the pipeline's version does
not run the new version until it is merged. This is because plans always run
the workflow from your default branch.

If you keep the pipeline in a private repository, other repositories can only
call it if they are in the same organization. The repository's Actions access
setting must also allow them to. Repositories in another organization have to
vendor a copy.

## Compared with other tools

This table compares the pipeline with tools that do similar jobs. Each row is
something a branch should not be able to do, or something you should not
have to give up. It reflects each tool's documentation at the time of
writing. Corrections are welcome.

| | This pipeline | HCP Terraform | Atlantis | tfaction | dflook actions | Digger (OpenTaco) |
|---|---|---|---|---|---|---|
| A branch cannot change the workflow that holds credentials | Yes | Yes | Yes | Depends on your workflow | Depends on your workflow | Depends on your workflow |
| A branch's Terraform code cannot read the credentials | Yes, sandboxed | No [^1] | No [^1] | No [^1] | No [^1] | No [^1] |
| A branch cannot redirect where providers send credentials | Yes, checked before the plan | With a run task you write | Not built in | With a policy you write [^2] | Not built in | Not built in |
| A branch cannot install unapproved providers | Yes | Only on self-hosted agents [^3] | Server setting | Yes, after download [^2] [^4] | Not built in | Not built in |
| Plans and applies use different credentials | Yes | Yes, with dynamic credentials [^5] | You build it | Yes, separate roles [^2] | You build it | Set in `digger.yml` [^2] |
| Applies the plan you reviewed | Saved plan file | Yes | Saved plan file | Saved plan file | Re-plans and compares, or a saved plan file | Only if plan storage is set up [^6] |
| Servers you have to run | None | None | Yes | None | None | None. There is an optional backend and a beta hosted option. |
| Other parties you trust with credentials | None if you pin to a commit or vendor | HashiCorp | None | The action, if you use a tag | The action, if you use a tag. Its image is pinned by digest. | The action, if you use a tag |

[^1]: Checked in October 2026. For Atlantis, tfaction, dflook's actions
    and Digger, we read the code that runs Terraform. Each passes Terraform
    the full environment, with no sandbox. For HCP Terraform, we read the
    documentation. It puts the OIDC token in the run's environment, and
    dynamic AWS credentials in a file the run can read. Its security model
    says it cannot prevent configuration from exfiltrating data during a
    plan.

[^2]: This setting lives in a file in the repository. A branch can change it.

[^3]: HashiCorp's hosted runs do not let you set your own CLI configuration.
    Self-hosted agents do. They are available on every plan, including Free.

[^4]: tfaction checks providers after `terraform init` has downloaded them. A
    provider that is not on the list cannot be used, but it is still
    downloaded.

[^5]: HCP Terraform applies workspace variables to every run. There is no way
    to give a static key to only the plan or only the apply. Dynamic
    credentials avoid this, but only for providers that accept OIDC.

[^6]: Without plan storage, Digger runs `terraform apply` without a plan file.
    That creates a new plan and applies it straight away, without checking it
    against the plan you reviewed.

### HCP Terraform

HCP Terraform is the closest match out of the box. Branches cannot change how
it runs. Its dynamic credentials include the run phase, so your cloud accounts
can tell plans and applies apart. It does not run plans for pull requests from
forks.

It has three gaps. First, a run's Terraform code can read its credentials.
Each run is its own virtual machine, which keeps runs apart. But inside a
run, the OIDC token is an environment variable, and dynamic AWS credentials
are a file. HashiCorp's own security model says it cannot prevent a
configuration from exfiltrating data during a plan. Second, static API keys
are shared by plans and applies. Third, you need self-hosted agents to
control which providers are installed. It is also a paid service beyond 500
managed resources, and it holds your state and your keys.

### Atlantis

Atlantis runs on your own server. That means you can control which providers
it installs, and you can run checks before a plan. Its own security docs warn
that a pull request can use a malicious provider or an `external` data source
to run code during a plan.

You have to run and maintain the server, and GitHub has to be able to reach it
with webhooks. The server holds the credentials for every repository it
serves. It has no built-in way to use different credentials for plan and
apply. By default, repositories cannot define their own workflows. If you
allow it, anyone who can open a pull request can run code on the server.

### tfaction, dflook's actions and Digger

These tools handle the routine work well. They find Terraform directories,
post plans as comments, store plans and manage locks.

tfaction has the most security features of the three. It supports separate
roles for plan and apply. It can fetch keys from AWS Secrets Manager. It
requires a list of allowed providers. It can run Conftest on your code before
the plan.

The problem is where these settings live. tfaction and Digger read their
settings from files in the repository. A branch can edit those files. So a
branch can add a provider to tfaction's allowed list, or remove a Conftest
policy. Both tools also let those files set environment variables for the
Terraform run. Digger's settings can also run shell commands.

In other words, a protection that lives in the repository can be turned off
by the branch it is meant to protect against. This pipeline also keeps its
settings in the repository. The difference is that it only reads them from
your default branch.

dflook's actions are different. Their pre-run commands are set in the
workflow, not in a settings file. But they have no security checks of their
own.

You can use any of these tools inside this pipeline. Just make sure that
nothing they read from the pull request can turn off a protection the
pipeline provides.

## When not to use this

- **You need plans on pull requests from forks.** This pipeline skips them.
  That is deliberate. If outside contributors change your infrastructure,
  plan their changes after a maintainer has reviewed them.
- **You need to run Terraform on macOS or Windows.** The sandbox only works
  on Linux.
- **You want a managed service.** HCP Terraform and similar services give you
  a hosted runner, a web interface, access control and audit logs. Use one of
  those if that matters more to you than keeping third parties away from your
  credentials.
- **You want to run apply from pull request comments.** This pipeline applies
  on merge. It does not support commands like `atlantis apply`.

## Risks that remain

No setup removes these risks completely. They are listed here so you can make
a decision about them.

- **A plan can reveal what its credential can read.** The branch can make the
  plan print it. Limit who can see plan output. Limit what the plan credential
  can reach.
- **Some providers have no credential that cannot make changes.** For those,
  the plan job holds a credential that can make changes. A branch still cannot
  run apply, and it cannot add steps to the plan job. But during the plan,
  that credential sits next to the branch's own Terraform code. Only the
  sandbox and the checks on that code protect it, and neither is perfect. If a
  branch gets past them, it could leak the credential. Or it could misuse the
  credential through a provider feature. For these providers, you have three
  choices. You can plan only after merge. You can require a reviewer on the
  plan environment, so that every plan waits for approval. Or you can accept
  the risk and write it down.
- **The sandbox only covers files.** A provider that can run programs gets
  around it, as described in
  [Terraform runs in a sandbox](#terraform-runs-in-a-sandbox). It does not
  block the network either. So a data source can still send data to any
  server it can reach. That data could be
  what the plan reads, or values the branch chooses. Also, Terraform code can
  read anything in the workspace or in Terraform's working files. That
  includes any credential a provider saves in its home directory. Finally,
  the sandbox is only as strong as the kernel's Landlock.
- **The settings check does not load code exactly as Terraform does.** It
  uses the same HCL library, so it reads each file the same way. But it does
  not use Terraform's own rules for putting files together. So it does not
  pass files it cannot compare, such as files in the JSON syntax and
  override files. A difference between its rules and Terraform's could still
  let a changed setting through.
- **A mistake in this pipeline matters more than usual.** Because plans use
  `pull_request_target`, the rules in this pipeline's code are what keep the
  pull request's code in its place. A bug in them could expose the plan
  credential to anyone who can push a branch. This is why the rules live here,
  where they can be reviewed and tested once.
- **Any workflow on your default branch can use the plan environment.** That
  is by design, since those workflows have been reviewed. But it means a
  careless workflow on your default branch can undo these protections. Keep
  other workflows away from the plan and apply environments.
- **API keys last a long time.** The pipeline keeps branches from reaching
  them. It does not help if a key leaks some other way. Rotate them. A secret
  store can make this easier, as described in
  [API keys are kept out of reach](#api-keys-are-kept-out-of-reach).
- **An apply can break the pipeline's own access.** If that happens, a person
  has to fix it using direct credentials. That is why emergency access is a
  requirement.

## Open questions

- **Pull requests from forks have not been tested end to end.** The fork
  check compares repository IDs. GitHub documents that a pull request from a
  fork carries the fork's ID, and testing confirmed that the check sees the
  pull request event from inside a called workflow. A test with a real fork is
  still needed.
- **Blocking the network.** The sandbox could also stop providers from
  reaching servers that are not on a list. But the list would have to name
  exact hosts, because many cloud domains also host other people's services.
  Keeping such a list up to date would be a lot of work.
- **Dependabot and Renovate.** Their pull requests come from the same
  repository, so they should be planned. But Dependabot has its own rules for
  tokens and secrets. They may stop its plans from getting environment secrets
  or OIDC tokens. This has not been tested.
- **A setup module.** This repository could include a module that creates the
  state bucket, the OIDC provider, and the plan and apply identities for a new
  user.
- **Updating vendored copies.** Whether to provide a tool that copies changes
  from this repository into a vendored copy.
- **A release policy.** What counts as a breaking change, and how releases are
  signed.
- **OpenTofu.** It behaves the same way in the ways that matter here, but it
  has not been tested.

## Working on this repository

The pipeline is the workflow in `.github/workflows/terraform.yml`, and the
actions it loads from this repository:

- `.github/actions/prepare-terraform` sets up the sandbox. The sandbox itself
  is `sandbox.py`.
- `.github/actions/install-comparison` builds a small Go program. It finds
  the roots, and it is the settings check.
- `.github/actions/read-config` reads and checks the config file.
- `.github/actions/export-environment-variables` exports the secrets and
  variables that the config names.
- `.github/actions/module-token` creates the token for private modules, and
  lets git use it.
- `.github/actions/check-latest` stops a job whose run's commit is no longer
  the latest on the default branch.

The workflow loads these with GitHub's self-repository syntax, `uses: $/...`.
That loads them from the same commit as the workflow. So a caller that pins
the workflow to a commit gets the actions from that commit too. In a private
repository, the job loading them needs `contents: read`.

The self-test loads the actions the same way. So a pull request here tests
the actions it changes.
