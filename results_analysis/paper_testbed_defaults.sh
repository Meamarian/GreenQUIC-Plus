#!/usr/bin/env bash
# Paper-testbed convenience defaults for GreenQUIC+.
#
# The management-routing values below make the supported wrappers zero-argument
# on our paper testbed. Another deployment can override SERVER/CLIENT/bastion/key
# GQ_* values without editing the repository.
#
# GQ_REMOTE_USER, GQ_REMOTE_ROOT and GQ_TEST_NIC_PCI also document fixed values
# used by the current paper workflow. The underlying setup/experiment code
# requires root, /root/mohsen and the recorded paper hardware layout; overriding
# those three helper variables alone does NOT make the core workflow portable to
# different privileges, paths or hardware.

if [[ -z "${GQ_CONTROL_REPO:-}" ]]; then
    _gq_defaults_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    GQ_CONTROL_REPO="$(cd -- "$_gq_defaults_here/.." && pwd)"
    unset _gq_defaults_here
fi

GQ_MAIN_BRANCH="${GQ_MAIN_BRANCH:-main}"
GQ_SERVER_HOST="${GQ_SERVER_HOST:-idex}"
GQ_CLIENT_HOST="${GQ_CLIENT_HOST:-tinyman}"
GQ_SERVER_TO_CLIENT_HOST="${GQ_SERVER_TO_CLIENT_HOST:-$GQ_CLIENT_HOST}"
GQ_BASTION="${GQ_BASTION:-mohsen@coinbase}"
GQ_SSH_KEY="${GQ_SSH_KEY:-$HOME/.ssh/id_ed25519}"
GQ_REMOTE_USER="${GQ_REMOTE_USER:-root}"
GQ_REMOTE_ROOT="${GQ_REMOTE_ROOT:-/root/mohsen}"
GQ_POS_SERVER_NODE="${GQ_POS_SERVER_NODE:-idex}"
GQ_POS_CLIENT_NODE="${GQ_POS_CLIENT_NODE:-tinyman}"
GQ_TEST_NIC_PCI="${GQ_TEST_NIC_PCI:-0000:18:00.0}"

export GQ_CONTROL_REPO GQ_MAIN_BRANCH
export GQ_SERVER_HOST GQ_CLIENT_HOST GQ_SERVER_TO_CLIENT_HOST
export GQ_BASTION GQ_SSH_KEY GQ_REMOTE_USER GQ_REMOTE_ROOT
export GQ_POS_SERVER_NODE GQ_POS_CLIENT_NODE GQ_TEST_NIC_PCI
