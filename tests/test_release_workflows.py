import json
import unittest
from pathlib import Path

import yaml

WORKFLOWS = Path(".github/workflows")


def workflow(name: str) -> str:
    return (WORKFLOWS / name).read_text(encoding="utf-8")


class ReleaseWorkflowCoverageTest(unittest.TestCase):
    def test_qualification_builds_every_non_publishing_family(self) -> None:
        text = workflow("qualify-release.yml")
        for contract in (
            "workflow_call:",
            "default: reusable",
            "source_sha: ${{ inputs.source_sha }}",
            "qualify-linux-x86-archives:",
            "qualify-linux-arm-archives:",
            "qualify-packages:",
            "publish: false",
            "qualification-summary:",
            "Enforce the complete release matrix",
            '"$X86_COUNT" -ne 2',
            '"$RPM_JOBS" -ne 30',
        ):
            self.assertIn(contract, text)

    def test_production_keeps_all_release_outputs(self) -> None:
        text = workflow("build-release.yml")
        for job in (
            "update-valkey-hashes:",
            "update-valkey-container:",
            "update-valkey-doc:",
            "update-valkey-helm:",
            "release-build-linux-x86-packages:",
            "release-build-linux-arm-packages:",
            "release-build-packages:",
            "update-try-valkey:",
            "update-valkey-website:",
            "trigger-valkey-bundle:",
        ):
            self.assertIn(job, text)
        self.assertIn("environment: release-publish", text)
        self.assertIn('SOURCE_SHA="$TAG_SHA"', text)
        self.assertIn('WORKFLOW_REF" != "refs/heads/main"', text)
        self.assertIn('"$APPROVER" != "$TRIGGERING_ACTOR"', text)
        self.assertIn('CURRENT_SHA=$(gh api "repos/${REPO}/commits/main"', text)
        self.assertIn('"$GITHUB_SHA" == "$CURRENT_SHA"', text)
        self.assertIn("Production automation is stale:", text)
        self.assertIn("release-publish must disable admin bypass", text)
        self.assertIn('if has("can_admins_bypass") then .can_admins_bypass else true end', text)
        self.assertNotIn(".can_admins_bypass // true", text)

    def test_archive_and_package_builds_use_exact_source_sha(self) -> None:
        archives = workflow("call-build-linux-archives.yml")
        packages = workflow("packages.yml")
        self.assertIn("ref: ${{ inputs.source_sha != '' && inputs.source_sha || inputs.version }}", archives)
        self.assertIn("HEAD_SHA=$(git rev-parse HEAD)", archives)
        self.assertIn("source_sha:", packages)
        self.assertIn("valkey/archive/${SHA}.tar.gz", packages)
        self.assertIn("SOURCE_SHA: ${{ inputs.source_sha }}", packages)
        self.assertIn('SOURCE_SHA="$TAG_SHA"', packages)
        self.assertIn("source_sha: ${{ steps.derive.outputs.source_sha }}", packages)
        self.assertEqual(
            packages.count("SOURCE_SHA: ${{ needs.process-inputs.outputs.source_sha }}"),
            2,
        )
        self.assertEqual(
            packages.count("          SHA: ${{ needs.process-inputs.outputs.source_sha }}"),
            2,
        )

    def test_candidate_code_never_shares_a_job_with_oidc(self) -> None:
        archives = workflow("call-build-linux-archives.yml")
        try_valkey = workflow("update-try-valkey.yml")
        archives = "\n".join(line for line in archives.splitlines() if not line.lstrip().startswith("#"))
        try_valkey = "\n".join(line for line in try_valkey.splitlines() if not line.lstrip().startswith("#"))
        archive_build = archives.split("  publish-valkey:", 1)[0]
        archive_publish = archives.split("  publish-valkey:", 1)[1]
        try_build = try_valkey.split("  upload-try-valkey:", 1)[0]
        try_publish = try_valkey.split("  upload-try-valkey:", 1)[1]
        self.assertNotIn("id-token: write", archive_build)
        self.assertNotIn("Configure AWS credentials", archive_build)
        self.assertIn("persist-credentials: false", archive_build)
        self.assertIn("id-token: write", archive_publish)
        self.assertNotIn("Make Valkey", archive_publish)
        self.assertNotIn("id-token: write", try_build)
        self.assertNotIn("Configure AWS credentials", try_build)
        self.assertEqual(
            try_build.count("persist-credentials: false"),
            try_build.count("uses: actions/checkout@"),
        )
        self.assertIn("id-token: write", try_publish)
        self.assertNotIn("Build Try Valkey image", try_publish)

    def test_hash_and_website_commits_are_signed_off(self) -> None:
        hashes = workflow("update-valkey-hashes.yml")
        website = workflow("update-valkey-website.yml")
        self.assertIn("source_sha:", hashes)
        self.assertIn('SHA=$(jq -r', hashes)
        self.assertIn("git commit -s", hashes)
        self.assertEqual(website.count("git commit -s"), 2)

    def test_cross_repo_qualification_checks_out_automation_implementation(self) -> None:
        qualification = workflow("qualify-release.yml")
        packages = workflow("packages.yml")
        self.assertNotIn("inputs.automation_repo", qualification)
        self.assertNotIn("inputs.automation_ref", qualification)
        self.assertNotIn("automation_repo:", packages)
        self.assertNotIn("automation_ref:", packages)
        checkout_count = packages.count("uses: actions/checkout@")
        self.assertGreater(checkout_count, 0)
        self.assertEqual(
            packages.count("repository: ${{ job.workflow_repository }}"),
            checkout_count,
        )
        self.assertEqual(
            packages.count("ref: ${{ job.workflow_sha }}"),
            checkout_count,
        )
        self.assertNotIn("github.workflow_sha", qualification)
        self.assertNotIn("github.workflow_sha", packages)
        self.assertIn("AUTOMATION_SHA: ${{ job.workflow_sha }}", qualification)
        self.assertIn("AUTOMATION_REPO: ${{ job.workflow_repository }}", qualification)
        self.assertIn("automation_sha:", qualification)
        self.assertIn("value: ${{ jobs.validate-inputs.outputs.automation_sha }}", qualification)
        self.assertIn("ref: ${{ needs.validate-inputs.outputs.automation_sha }}", qualification)

    def test_production_helpers_use_the_approved_automation_revision(self) -> None:
        for name in (
            "update-valkey-container.yml",
            "update-try-valkey.yml",
            "update-valkey-website.yml",
            "update-valkey-helm.yml",
        ):
            text = workflow(name)
            self.assertIn("repository: ${{ job.workflow_repository }}", text, name)
            self.assertIn("ref: ${{ job.workflow_sha }}", text, name)
            self.assertNotIn(
                "repository: ${{ github.repository_owner }}/valkey-release-automation",
                text,
                name,
            )

    def test_release_path_uses_one_automation_approval(self) -> None:
        build = workflow("build-release.yml")
        packages = workflow("packages.yml")
        self.assertEqual(build.count("environment: release-publish"), 1)
        self.assertIn("release_gate_passed: true", build)
        self.assertIn("release_gate_passed:", packages)
        # The standalone deployment gates were removed by maintainer decision
        # (rubber-stamped approvals provide no review); the release path's
        # single prod-approval in build-release.yml is the only environment
        # gate, and no other workflow may quietly reintroduce one.
        self.assertNotIn("standalone-approval", packages)
        self.assertEqual(packages.count("environment: release-publish"), 0)
        self.assertEqual(
            workflow("update-try-valkey.yml").count("environment: release-publish"), 0
        )

    def test_standalone_package_publication_refuses_release_candidates(self) -> None:
        # With the standalone approval gate gone, the GA-only policy for the
        # production package repository is enforcement in code, not review:
        # a direct dispatch must not be the one entry point that can put a
        # prerelease in front of package users.
        packages = workflow("packages.yml")
        self.assertIn(
            "refusing to publish release candidate", packages
        )
        self.assertIn('"$EVENT_NAME" == "workflow_dispatch" && "$PUBLISH" == "true"', packages)

    def test_eol_debian_build_and_test_use_immutable_package_snapshot(self) -> None:
        platforms = json.loads(
            Path(".github/package-platforms.json").read_text(encoding="utf-8")
        )
        debian11 = next(
            platform
            for platform in platforms["deb"]["platform"]
            if platform["id"] == "debian11"
        )
        self.assertRegex(debian11["apt_snapshot"], r"^\d{8}T\d{6}Z$")

        workflow_text = workflow("packages.yml")
        self.assertIn(
            "APT_SNAPSHOT: ${{ matrix.platform.apt_snapshot || '' }}", workflow_text
        )
        self.assertIn('-e APT_SNAPSHOT="$APT_SNAPSHOT"', workflow_text)
        # Matrix values reach the shell through step env, never interpolated
        # into shell source.
        self.assertNotIn('-e APT_SNAPSHOT="${{', workflow_text)
        self.assertIn(
            "snapshot.debian.org/archive/debian/${APT_SNAPSHOT}", workflow_text
        )
        # apt-get update and install must be separate commands: set -e does
        # not fire when the left operand of && fails, which would commit a
        # systemd-less image that only breaks at /sbin/init.
        self.assertNotIn("apt-get update && apt-get install", workflow_text)
        self.assertIn("apt-get update\n", workflow_text)
        self.assertIn("apt-get install -y systemd systemd-sysv", workflow_text)

        script = Path("scripts/build-deb.sh").read_text(encoding="utf-8")
        self.assertIn("snapshot.debian.org/archive/debian/${APT_SNAPSHOT}", script)
        self.assertIn(
            "snapshot.debian.org/archive/debian-security/${APT_SNAPSHOT}", script
        )
        self.assertIn("check-valid-until=no", script)

    def test_downstream_prs_notify_the_production_approver_once(self) -> None:
        build = workflow("build-release.yml")
        self.assertIn("release_owner: ${{ steps.approver.outputs.login }}", build)
        # The notification is reconciled on every run that has a PR, guarded
        # by an idempotence marker: gating on pull-request-operation ==
        # 'created' meant a comment that failed after PR creation was never
        # retried, because the rerun sees the PR as 'updated'.
        for name in (
            "update-valkey-container.yml",
            "update-valkey-doc.yml",
            "update-valkey-helm.yml",
            "update-valkey-website.yml",
        ):
            text = workflow(name)
            self.assertNotIn("pull-request-operation == 'created'", text, name)
            self.assertIn("steps.create-pr.outputs.pull-request-number != ''", text, name)
            self.assertIn("<!-- release-owner-notification -->", text, name)
            # The body is built with printf: a body continued on an indented
            # YAML line renders as a Markdown code block and the @mention
            # never pings.
            self.assertIn("BODY=$(printf", text, name)
            # Restored from the pre-reconcile version of this test: the
            # approval identity must still flow to every downstream PR.
            self.assertIn("release_owner:", workflow("build-release.yml"))
            self.assertIn("RELEASE_OWNER: ${{ inputs.release_owner }}", text, name)
        # apt keeps prior patches in the index only with --multiversion.
        self.assertIn(
            "dpkg-scanpackages --multiversion",
            Path("scripts/publish-to-s3.sh").read_text(encoding="utf-8"),
        )

    def test_helm_update_is_reviewable_and_cannot_publish_a_chart(self) -> None:
        text = workflow("update-valkey-helm.yml")
        self.assertIn("draft: true", text)
        self.assertIn("permission-pull-requests: write", text)
        self.assertNotIn("packages/helm", text)
        self.assertNotIn("docker/build-push-action", text)


if __name__ == "__main__":
    unittest.main()


class TestPermissionMesh(unittest.TestCase):
    """Every reusable-workflow call must satisfy GitHub's permission validator.

    GitHub validates a called workflow's job `permissions:` blocks against the
    CALLER JOB's effective permissions at run startup - including jobs whose
    `if:` would skip them, and transitively through nested calls. A violation
    is a startup_failure in production (this broke the 9.2.0-rc1 builds until
    the callers granted the actions:read their approval jobs declared). This
    test enforces the same subset rule statically so the break happens in CI.
    """

    _RANK = {"none": 0, "read": 1, "write": 2}
    _SCOPES = [
        "actions", "attestations", "checks", "contents", "deployments",
        "discussions", "id-token", "issues", "packages", "pages",
        "pull-requests", "repository-projects", "security-events", "statuses",
    ]

    @classmethod
    def _norm(cls, perms):
        if perms is None:
            return None
        if perms == "read-all":
            return {s: "read" for s in cls._SCOPES}
        if perms == "write-all":
            return {s: "write" for s in cls._SCOPES}
        return dict(perms or {})

    @classmethod
    def _load(cls):
        workflows = {}
        for path in sorted(WORKFLOWS.glob("*.yml")):
            doc = yaml.safe_load(path.read_text())
            wf_perms = cls._norm(doc.get("permissions"))
            jobs = {}
            for name, job in (doc.get("jobs") or {}).items():
                own = cls._norm(job.get("permissions"))
                jobs[name] = {
                    "own": own,
                    "effective": own if own is not None else wf_perms,
                    "uses": job.get("uses"),
                }
            workflows[path.name] = {"wf_perms": wf_perms, "jobs": jobs}
        return workflows

    @classmethod
    def _requirements(cls, workflows, wf_name, chain):
        """Every permission request in wf_name and its nested local calls."""
        reqs = []
        wf = workflows[wf_name]
        for jname, job in wf["jobs"].items():
            label = f"{wf_name}:{jname}"
            req = job["own"] if job["own"] is not None else wf["wf_perms"]
            reqs.append((label, req or {}))
            uses = job["uses"] or ""
            if uses.startswith("./"):
                nested = uses.rsplit("/", 1)[-1]
                if nested in workflows and nested not in chain:
                    reqs.extend(cls._requirements(workflows, nested, chain + [nested]))
        return reqs

    def test_every_local_call_satisfies_the_permission_validator(self) -> None:
        workflows = self._load()
        violations = []
        edges = 0
        for wname, wf in workflows.items():
            for jname, job in wf["jobs"].items():
                uses = job["uses"] or ""
                if not uses.startswith("./"):
                    continue
                called = uses.rsplit("/", 1)[-1]
                self.assertIn(called, workflows, f"{wname}:{jname} calls missing {called}")
                edges += 1
                cap = job["effective"] or {}
                for label, req in self._requirements(workflows, called, [called]):
                    for scope, level in req.items():
                        have = cap.get(scope, "none")
                        if self._RANK.get(have, 0) < self._RANK.get(level, 0):
                            violations.append(
                                f"{wname}:{jname} -> {label}: needs {scope}:{level}, "
                                f"caller grants {scope}:{have} (startup_failure in prod)"
                            )
        self.assertGreater(edges, 0, "no call edges found; the mesh test is not testing anything")
        self.assertEqual(violations, [])

    def test_no_job_relies_on_the_implicit_repository_default(self) -> None:
        # A job with neither its own nor a workflow-level permissions block
        # gets whatever the repository settings say, which nobody reviews in
        # a PR. Every job must resolve to an explicit, reviewed grant.
        workflows = self._load()
        implicit = [
            f"{wname}:{jname}"
            for wname, wf in workflows.items()
            for jname, job in wf["jobs"].items()
            if job["effective"] is None
        ]
        self.assertEqual(implicit, [])
