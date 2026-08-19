import os
import datetime
import jwt
import requests
import logging
from cryptography.hazmat.primitives import serialization
import azure.functions as func

def main(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("GetGitHubToken function started")
    try:
        app_id = os.environ.get("GITHUB_APP_ID")
        installation_id = os.environ.get("GITHUB_INSTALLATION_ID")
        private_key = os.environ.get("GITHUB_PRIVATE_KEY")

        if not app_id:
            logging.error("GITHUB_APP_ID is missing from environment variables")
            return func.HttpResponse("Missing GITHUB_APP_ID", status_code=500)
        if not installation_id:
            logging.error("GITHUB_INSTALLATION_ID is missing from environment variables")
            return func.HttpResponse("Missing GITHUB_INSTALLATION_ID", status_code=500)
        if not private_key:
            logging.error("GITHUB_PRIVATE_KEY is missing from environment variables")
            return func.HttpResponse("Missing GITHUB_PRIVATE_KEY", status_code=500)

        logging.info(f"App ID: {app_id}")
        logging.info(f"Installation ID: {installation_id}")
        logging.info(f"Private key length: {len(private_key)}")
        logging.info(f"Private key PEM header detected: {private_key.lstrip().startswith('-----BEGIN')}")

        now = datetime.datetime.now(datetime.timezone.utc)
        payload = {
            "iat": int(now.timestamp()),
            "exp": int((now + datetime.timedelta(minutes=10)).timestamp()),
            "iss": app_id,
        }
        logging.info(f"JWT payload: {payload}")
        try:
            key = serialization.load_pem_private_key(private_key.encode(), password=None)
        except Exception as key_error:
            logging.error(f"Error loading private key: {key_error}")
            return func.HttpResponse("Invalid private key format", status_code=500)

        jwt_token = jwt.encode(payload, key, algorithm="RS256")
        logging.info("JWT successfully generated")

        url = f"https://api.github.com/app/installations/{installation_id}/access_tokens"
        headers = {"Authorization": f"Bearer {jwt_token}", "Accept": "application/vnd.github+json"}
        logging.info(f"POSTing to GitHub API: {url}")
        try:
            r = requests.post(url, headers=headers, timeout=10)
            r.raise_for_status()
        except Exception as api_error:
            logging.error(f"GitHub API error: {api_error}")
            return func.HttpResponse("GitHub API error", status_code=500)
        token = r.json().get("token")
        if not token:
            logging.error(f"No token found in GitHub response: {r.text}")
            return func.HttpResponse("No token in response", status_code=500)

        logging.info("GitHub token successfully retrieved")
        return func.HttpResponse(token, mimetype="text/plain")
    except Exception as e:
        logging.error(f"Error in GetGitHubToken: {str(e)}")
        return func.HttpResponse("Internal Server Error", status_code=500)
