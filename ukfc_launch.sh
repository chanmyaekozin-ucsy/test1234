#!/bin/bash

echo "----------------------------------------"
echo "🚀 Starting Advanced Launch Script (v2)"
echo "----------------------------------------"

# 1. AUTO-UPDATE FROM GITHUB
if [ -n "$GIT_ADDRESS" ]; then
    echo "🔍 [AUTO-GIT] Checking for updates..."
    
    # Configure Identity (Prevents commit errors)
    git config --global user.email "bot@server.local"
    git config --global user.name "Server Bot"

    # Add safe directory to prevent permission errors
    git config --global --add safe.directory /home/container

    if [ -d .git ]; then
        echo "📂 .git folder found. Pulling latest changes..."
        git pull origin "$GIT_BRANCH"
    else
        echo "⚠️ Folder is not empty but not a Git repo."
        echo "🔄 Initializing Git and forcing sync with remote..."
        
        # Initialize git in the current folder
        git init
        git remote add origin "$GIT_ADDRESS"
        git fetch origin "$GIT_BRANCH"
        
        # FORCE the local files to match the GitHub repository
        # Warning: This overwrites local changes with the GitHub version
        git reset --hard origin/"$GIT_BRANCH"
        
        echo "✅ Sync complete."
    fi
else
    echo "⚠️ No GIT_ADDRESS set. Skipping auto-update."
fi

echo "----------------------------------------"

# 2. INSTALL REQUIREMENTS
if [ -f "Backend-Host-Python/requirements.txt" ]; then
    echo "📦 Installing dependencies from requirements.txt..."
    pip install -r requirements.txt
else
    echo "⚠️ No requirements.txt found. Skipping pip install."
fi

echo "----------------------------------------"

# 3. START THE BOT
echo "🔥 Starting Gunicorn Server..."
python Backend-Host-Python/init_db.py
