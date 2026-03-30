#!/usr/bin/env python3

import argparse
import datetime as dt
import json
import os
import sqlite3
import sys
from pathlib import Path


DEFAULT_DB = Path.home() / "tasks" / "memory.db"


SCHEMA = """
CREATE TABLE IF NOT EXISTS task_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    recorded_at TEXT NOT NULL,
    task_name TEXT NOT NULL,
    project TEXT NOT NULL,
    task_type TEXT,
    description TEXT,
    required_repos TEXT,
    branch_name TEXT,
    state TEXT,
    detail TEXT,
    artifacts_dir TEXT,
    log_file TEXT,
    changed_repos TEXT,
    backend_evidence TEXT,
    sufficiency_review TEXT,
    qa_review TEXT,
    related_prs TEXT
);

CREATE INDEX IF NOT EXISTS idx_task_runs_task_name ON task_runs(task_name);
CREATE INDEX IF NOT EXISTS idx_task_runs_project ON task_runs(project);
CREATE INDEX IF NOT EXISTS idx_task_runs_recorded_at ON task_runs(recorded_at DESC);
"""


def db_path_from_args(args: argparse.Namespace) -> Path:
    return Path(args.db or DEFAULT_DB)


def connect(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.executescript(SCHEMA)
    return conn


def cmd_init(args: argparse.Namespace) -> int:
    conn = connect(db_path_from_args(args))
    conn.close()
    print(f"initialized {db_path_from_args(args)}")
    return 0


def read_text(path_value: str | None) -> str:
    if not path_value:
        return ""
    path = Path(path_value)
    if not path.exists():
        return ""
    try:
        return path.read_text(encoding="utf-8")
    except Exception:
        return ""


def cmd_record(args: argparse.Namespace) -> int:
    conn = connect(db_path_from_args(args))
    payload = {
        "recorded_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "task_name": args.task_name,
        "project": args.project,
        "task_type": args.task_type or "",
        "description": args.description or "",
        "required_repos": args.required_repos or "",
        "branch_name": args.branch_name or "",
        "state": args.state or "",
        "detail": args.detail or "",
        "artifacts_dir": args.artifacts_dir or "",
        "log_file": args.log_file or "",
        "changed_repos": args.changed_repos or "",
        "backend_evidence": read_text(args.backend_evidence_file),
        "sufficiency_review": read_text(args.sufficiency_review_file),
        "qa_review": read_text(args.qa_review_file),
        "related_prs": read_text(args.related_prs_file),
    }
    conn.execute(
        """
        INSERT INTO task_runs (
            recorded_at, task_name, project, task_type, description,
            required_repos, branch_name, state, detail, artifacts_dir, log_file,
            changed_repos, backend_evidence, sufficiency_review, qa_review, related_prs
        ) VALUES (
            :recorded_at, :task_name, :project, :task_type, :description,
            :required_repos, :branch_name, :state, :detail, :artifacts_dir, :log_file,
            :changed_repos, :backend_evidence, :sufficiency_review, :qa_review, :related_prs
        )
        """,
        payload,
    )
    conn.commit()
    conn.close()
    print(f"recorded task run for {args.task_name}")
    return 0


def cmd_search(args: argparse.Namespace) -> int:
    conn = connect(db_path_from_args(args))
    needle = f"%{args.query}%"
    rows = conn.execute(
        """
        SELECT recorded_at, task_name, project, task_type, state, detail
        FROM task_runs
        WHERE task_name LIKE ?
           OR project LIKE ?
           OR description LIKE ?
           OR backend_evidence LIKE ?
           OR sufficiency_review LIKE ?
           OR qa_review LIKE ?
           OR related_prs LIKE ?
        ORDER BY recorded_at DESC
        LIMIT ?
        """,
        (needle, needle, needle, needle, needle, needle, needle, args.limit),
    ).fetchall()
    for row in rows:
        print(" | ".join(str(col or "") for col in row))
    conn.close()
    return 0


def cmd_history(args: argparse.Namespace) -> int:
    conn = connect(db_path_from_args(args))
    rows = conn.execute(
        """
        SELECT recorded_at, task_name, task_type, state, detail
        FROM task_runs
        WHERE project = ?
        ORDER BY recorded_at DESC
        LIMIT ?
        """,
        (args.project, args.limit),
    ).fetchall()
    for row in rows:
        print(" | ".join(str(col or "") for col in row))
    conn.close()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Task memory for the orchestrator")
    parser.add_argument("--db", help="Path to SQLite database")
    sub = parser.add_subparsers(dest="command", required=True)

    init_p = sub.add_parser("init")
    init_p.set_defaults(func=cmd_init)

    rec = sub.add_parser("record")
    rec.add_argument("--task-name", required=True)
    rec.add_argument("--project", required=True)
    rec.add_argument("--task-type")
    rec.add_argument("--description")
    rec.add_argument("--required-repos")
    rec.add_argument("--branch-name")
    rec.add_argument("--state")
    rec.add_argument("--detail")
    rec.add_argument("--artifacts-dir")
    rec.add_argument("--log-file")
    rec.add_argument("--changed-repos")
    rec.add_argument("--backend-evidence-file")
    rec.add_argument("--sufficiency-review-file")
    rec.add_argument("--qa-review-file")
    rec.add_argument("--related-prs-file")
    rec.set_defaults(func=cmd_record)

    search = sub.add_parser("search")
    search.add_argument("query")
    search.add_argument("--limit", type=int, default=20)
    search.set_defaults(func=cmd_search)

    hist = sub.add_parser("history")
    hist.add_argument("project")
    hist.add_argument("--limit", type=int, default=20)
    hist.set_defaults(func=cmd_history)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
