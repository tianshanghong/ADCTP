#!/bin/bash

# Helper script to create a Cloudflare Tunnel and prepare credentials file
# This script ONLY creates the tunnel - DNS records are managed by Ansible

set -e

# Ensure cloudflared is installed
if ! command -v cloudflared &> /dev/null; then
    echo "cloudflared is not installed. Installing now..."
    
    # Check the OS and install accordingly
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        curl -L --output cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x cloudflared
        sudo mv cloudflared /usr/local/bin
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        brew install cloudflare/cloudflare/cloudflared
    else
        echo "Unsupported OS. Please install cloudflared manually."
        exit 1
    fi
fi

# Check if jq is installed (required for JSON parsing)
if ! command -v jq &> /dev/null; then
    echo "Installing jq for JSON parsing..."
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y jq
        elif command -v yum &> /dev/null; then
            sudo yum install -y jq
        else
            echo "Error: Couldn't install jq. Please install it manually."
            exit 1
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        brew install jq
    else
        echo "Error: Couldn't install jq. Please install it manually."
        exit 1
    fi
fi

# Check if the user is logged in
if [ ! -f ~/.cloudflared/cert.pem ]; then
    echo "You need to log in to Cloudflare first."
    cloudflared login
fi

# Display title
echo "=============================================="
echo "        Cloudflare Tunnel Creator Tool        "
echo "=============================================="

# Ask for the tunnel name
read -p "Enter a name for your tunnel: " TUNNEL_NAME

if [[ -z "$TUNNEL_NAME" ]]; then
    echo "Error: Tunnel name cannot be empty."
    exit 1
fi

# Check if tunnel with this name already exists
echo "Checking for existing tunnels..."
EXISTING_TUNNELS=$(cloudflared tunnel list -o json 2>/dev/null || echo "[]")

# Validate JSON
if ! echo "$EXISTING_TUNNELS" | jq empty &>/dev/null; then
    echo "Warning: Could not parse tunnel list. Will attempt to create a new tunnel."
    EXISTING_TUNNELS="[]"
fi

if echo "$EXISTING_TUNNELS" | jq -e ".[] | select(.name == \"$TUNNEL_NAME\")" &>/dev/null; then
    echo "A tunnel with the name '$TUNNEL_NAME' already exists."
    TUNNEL_ID=$(echo "$EXISTING_TUNNELS" | jq -r ".[] | select(.name == \"$TUNNEL_NAME\") | .id")
    echo "Using existing tunnel ID: $TUNNEL_ID"
    
    # Check if local credentials file exists
    if [ ! -f "files/${TUNNEL_ID}.json" ] && [ -f ~/.cloudflared/${TUNNEL_ID}.json ]; then
        echo "Copying existing credentials to project..."
        mkdir -p files
        cp ~/.cloudflared/${TUNNEL_ID}.json files/
    fi
else
    # Create the tunnel
    echo "Creating new tunnel '$TUNNEL_NAME'..."
    # Capture the entire output of the tunnel creation
    TUNNEL_OUTPUT=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1)
    
    if [[ $? -ne 0 ]]; then
        echo "Error creating tunnel: $TUNNEL_OUTPUT"
        exit 1
    fi
    
    echo "$TUNNEL_OUTPUT"
    
    # Extract the UUID tunnel ID using regex patterns
    # First try to find tunnelID=<uuid>
    TUNNEL_ID=$(echo "$TUNNEL_OUTPUT" | grep -o "tunnelID=[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}" | cut -d= -f2)
    
    # If not found, try to match "Created tunnel X with id <uuid>"
    if [ -z "$TUNNEL_ID" ]; then
        TUNNEL_ID=$(echo "$TUNNEL_OUTPUT" | grep -o "with id [a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}" | awk '{print $3}')
    fi
    
    # Last resort, try to find any UUID in the output
    if [ -z "$TUNNEL_ID" ]; then
        TUNNEL_ID=$(echo "$TUNNEL_OUTPUT" | grep -o "[a-f0-9]\{8\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{4\}-[a-f0-9]\{12\}")
    fi
    
    if [ -z "$TUNNEL_ID" ]; then
        echo "Error: Failed to extract tunnel ID from the output."
        echo "Please check the Cloudflare dashboard or run 'cloudflared tunnel list' to find your tunnel ID."
        exit 1
    fi
    
    echo "Successfully created tunnel with ID: $TUNNEL_ID"
fi

# Ask for domain
read -p "Enter your primary domain (e.g., example.com): " DOMAIN

if [[ -z "$DOMAIN" ]]; then
    echo "Error: Domain cannot be empty."
    exit 1
fi

# Check if credentials file exists locally before copying
if [ ! -f "files/${TUNNEL_ID}.json" ]; then
    # Check if it exists in cloudflared directory
    if [ -f ~/.cloudflared/${TUNNEL_ID}.json ]; then
        # Copy the credentials file to the files directory
        mkdir -p files
        cp ~/.cloudflared/${TUNNEL_ID}.json files/
        echo "Credentials file copied to files/${TUNNEL_ID}.json"
    else
        echo "Warning: Credentials file not found at ~/.cloudflared/${TUNNEL_ID}.json"
        echo "You may need to fetch it manually or check the Cloudflare dashboard."
        
        # Try to find any JSON files that might be the credentials
        POTENTIAL_FILES=$(find ~/.cloudflared -name "*.json" -type f -newer ~/.cloudflared/cert.pem 2>/dev/null | head -n 5)
        if [ ! -z "$POTENTIAL_FILES" ]; then
            echo "Found potential credential files:"
            echo "$POTENTIAL_FILES"
            echo "Try copying one of these files to files/${TUNNEL_ID}.json"
        fi
    fi
else
    echo "Credentials file already exists at files/${TUNNEL_ID}.json"
fi

# Display next steps with clear separation of concerns
echo ""
echo "=============================================="
echo "        Tunnel Setup Complete                 "
echo "=============================================="
echo ""
echo "Tunnel Name: $TUNNEL_NAME"
echo "Tunnel ID:   $TUNNEL_ID"
echo "Domain:      $DOMAIN"
echo ""
echo "IMPORTANT: DNS records will be managed by Ansible, not this script."
echo ""
echo "Next Steps:"
echo "1. Get your Cloudflare Zone ID from the Cloudflare dashboard:"
echo "   - Log in to Cloudflare"
echo "   - Select your domain"
echo "   - Zone ID is displayed on the Overview page"
echo ""
echo "2. Update your group_vars/all.yml with the following values:"
echo "   domains:"
echo "     - domain: \"$DOMAIN\""
echo "       zone_id: \"YOUR_ZONE_ID_HERE\"  # Replace with actual Zone ID"
echo "   tunnel_id: \"$TUNNEL_ID\""
echo ""
echo "3. Run the Ansible playbook to deploy your infrastructure"
echo "   and create DNS records pointing to your tunnel:"
echo "   ansible-playbook playbook.yml"
echo ""
echo "4. After Ansible runs, you can access your services at:"
echo "   https://traefik.$DOMAIN (reverse proxy dashboard)"
echo "==============================================" 