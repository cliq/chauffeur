# Chauffeur — MVP overview

- Date: 2026-09-15
- Working product name: Chauffeur
- Audience: the developer's own daily use on macOS

## Product

Chauffeur is an agent development environment (ADE) for running multiple Codex and Claude Code CLI sessions across related repositories. It combines real terminals, reusable agent presets, independent project windows, Git worktrees, and communication between agents.

The two primary problems are choosing the correct personal or client configuration for each agent and keeping different projects in separate windows on different macOS desktops (Spaces).

## Everyday workflow

1. Maintain teams such as **Personal**, **Client 1**, and **Client 2**. Each contains named Codex and/or Claude Code agent presets pointing to existing CLI configuration directories.
2. Create a project, select a team, and either select repositories discovered under a folder or start empty and add folders from anywhere later.
3. Open the project in its own window. Place each project window on the desired macOS desktop.
4. Choose a repository, an existing checkout or a new worktree, and an agent preset. Work directly in the CLI's terminal interface.
5. Run several sessions, see which need attention, and let agents message peers or delegate a specific task to another visible session in the same agent group.
6. Close windows or quit Chauffeur while agents continue. Reopen a project to reconnect to its running sessions.

Example: **Client 1 / Project 1**, **Client 1 / Project 2**, **Personal / Project 1**, and **Client 2 / Project 1** each have a window. The first two share the Client 1 team while keeping separate session lists and agent communication.

## Core model

| Concept | Responsibility |
| --- | --- |
| Team | Reusable collection of agent presets, shared by reference across projects. |
| Agent preset | CLI type, existing configuration directory, and launch defaults. |
| Project | Named collection of folders, selected team, and session/worktree records. |
| Agent group | Named team of sessions within a project, with its own MCP communication boundary. A project can contain several groups. |
| Repository folder | Existing folder registered in the project; repositories support managed worktrees. |
| Worktree | Separate checkout belonging to one repository, usable by one or more explicitly associated sessions. |
| Session | Durable agent identity, conversation reference, terminal process, agent preset snapshot, and primary working directory. |
| Project window | A view into the project's repositories, their checkouts, and the sessions running in each. |

Each session has one primary working directory and may also access other repositories in its project. A worktree is created for one repository at a time. Additional repository paths do not automatically gain separate worktrees.

Each session belongs to one named group within its project, and delegated children inherit it. As a convenience, projects start with a **Default** group; the user can create additional groups for separate tasks. Group separation applies to MCP communication; repository paths can still be shared.

## Window and terminal experience

Each project gets a native macOS window whose sidebar switches between a repository tree (main checkout and worktrees, with attention badges) and a flat session list with group filter and search. Selecting a checkout shows its sessions above one terminal, with actions to launch an agent or open a shell there. Project name, team, agent preset, group, and working directory remain easy to identify.

Keyboard actions cover opening projects, starting sessions, switching terminals, and jumping to the next session needing input. Normal macOS window and Spaces controls determine desktop placement. Reopening an already open project focuses its existing window.

## Configuration and communication

Agent Presets reference directories the user already maintains. The MVP does not create CLI configuration directories or manage sign-in. Changes to shared agent presets affect new sessions; existing sessions retain their recorded launch configuration. Native configuration files remain owned by the user and CLI.

Chauffeur runs one local Model Context Protocol (MCP) server for all Codex and Claude Code sessions. It owns agent-group membership, routes messages, and launches delegated sessions. Every connection is associated with a session and its group; agents discover and communicate with members of that group only. Shared teams and configuration directories never merge group mailboxes.

A Chauffeur skill explains how to use the MCP tools. CLI-specific adapters configure each agent's connection to the shared server without storing a mutable “current group” in a shared agent preset directory. The MCP tools provide communication; the skill supplies workflow guidance.

The background service owns agent processes and terminals independently of project windows. Closing a window or quitting the UI detaches the view. Reboot, logout, or service failure requires recovery and is distinct from reconnecting to a process that is still running.

## Delivery focus

The MVP is a locally built app for personal use. It prioritizes correct profile selection, multiple project windows, reliable terminals, worktree management, and explicit agent delegation. Public distribution, a custom chat interface, a code editor, cloud execution, and autonomous team orchestration are later scope.

The [detailed MVP PRD](mvp-prd.md) defines requirements, acceptance criteria, implementation validation, and delivery stages. The [implementation plan](mvp-implementation-plan.md) records the technical decisions and ordered work for delivering them.
