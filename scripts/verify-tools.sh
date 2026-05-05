#!/bin/bash
echo "=== Checking DevOps Tools ==="

check_tool() {
    if command -v "$1" &> /dev/null; then
        echo "✅ $1: $($1 $2 2>&1 | head -1)"
    else
        echo "❌ $1: NOT FOUND"
    fi
}

check_tool az version
check_tool terraform version
check_tool kubectl version --client --short
check_tool helm version --short
check_tool docker version --format '{{.Client.Version}}'
check_tool git --version
check_tool gh --version
check_tool kubelogin --version
check_tool jq --version

echo ""
echo "=== Azure Login Status ==="
az account show --query "{Subscription:name, SubscriptionId:id, State:state}" 2>/dev/null || echo "❌ Not logged in to Azure"

echo ""
echo "=== GitHub Auth Status ==="
gh auth status 2>&1 | head -5