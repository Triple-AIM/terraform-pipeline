# Security

## Reporting a problem

Please report security problems privately. Do not open a public issue.

Use GitHub's private vulnerability reporting. On this repository's
**Security** tab, choose **Report a vulnerability**.

A useful report says:

- what an attacker can do, and what they need first, such as the right to
  push a branch
- the steps to show it
- the commit of the pipeline you tested

## What counts

A security problem is a way to break one of the pipeline's promises. For
example:

- Code from a pull request reads a plan or apply credential.
- A pull request changes where a provider sends its credential, and is still
  planned.
- A provider that is not in the config is installed.
- The pipeline runs when it should refuse to, such as with an environment
  that allows any branch.

The README's [Risks that remain](README.md#risks-that-remain) are already
known. A report about one of them is still welcome if it goes further than
the README says.

Problems in Terraform, in a provider, or in GitHub Actions itself belong
with those projects.

## What to expect

This pipeline is shared as is. Every report will be read. But there is no
promise of a response time or a fix.

When a problem is confirmed and fixed, the fix goes to the default branch,
and an advisory is published. Pinned callers then choose when to move to
the fixed commit.
