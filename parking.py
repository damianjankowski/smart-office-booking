#!/usr/bin/env python3

import os
import logging
import sys
from datetime import date, timedelta, datetime
import requests
import json
import time
import random

START_HOUR = "08"
END_HOUR = "18"
MAIL_USER = os.getenv("MAIL_USER")
PLATE_NUMBER = os.getenv("PLATE_NUMBER")
PASSWORD = os.getenv("PASSWORD_PARKING")
LOCATION_IDS = ["19", "29"]
BASE_URL = os.getenv("BASE_URL")
BOOKING_DATE = os.getenv("BOOKING_DATE")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)

def get_target_date() -> str | None:
    if BOOKING_DATE:
        logging.info(f"Manual booking date override detected: {BOOKING_DATE}")
        return BOOKING_DATE
    today = date.today()
    day_of_week = today.weekday()  # Monday is 0, Sunday is 6

    if 0 <= day_of_week <= 2:  # Monday - Wednesday
        days_to_add = 2
    elif 3 <= day_of_week <= 4:  # Thursday - Friday
        days_to_add = 4
    else: # Saturday, Sunday
        logging.info("Script is not intended to be run on weekends. No action taken.")
        return None

    target_date = today + timedelta(days=days_to_add)
    logging.debug(f"Target date: {target_date.strftime('%Y-%m-%d')}")
    return target_date.strftime("%Y-%m-%d")

def login(session: requests.Session) -> str | None:
    logging.info("Attempting to log in...")
    login_url = f"{BASE_URL}/login"
    payload = {
        "username": f"{MAIL_USER}",
        "password": PASSWORD
    }
    try:
        response = session.post(login_url, data=payload)
        response.raise_for_status()
        token = response.json().get("accessToken")
        if token:
            logging.info("Login successful. Token acquired.")
            return token
        else:
            logging.error(f"Login failed. 'accessToken' not in response. Response: {response.text}")
            return None
    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred during login: {e}")
        return None

def get_available_spaces(session: requests.Session, token: str, target_date: str, location_id: str) -> list[str]:
    logging.info(f"Fetching available spaces for {target_date} at location {location_id}...")
    search_url = f"{BASE_URL}/api/2.0/search-resource"
    headers = {"Authorization": f"Bearer {token}"}

    start_time = f"{target_date}T{START_HOUR}:00+01:00"
    end_time = f"{target_date}T{END_HOUR}:00+01:00"
    dates_list = [{"startTime": start_time, "endTime": end_time}]

    payload = {
        "startTime": start_time,
        "endTime": end_time,
        "dates": json.dumps(dates_list),
        "type": "parking",
        "emailAddress": f"{MAIL_USER}",
        "lang": "pl"
    }

    try:
        response = session.post(search_url, headers=headers, data=payload)
        response.raise_for_status()
        data = response.json()
        logging.debug(f"Data: {data}")
        location_data = data.get("locations", {}).get(location_id)
        if not location_data:
            logging.warning(f"No data found for location ID {location_id}.")
            return []
        resources = location_data.get("resources", [])
        available_spaces = [str(r["id"]) for r in resources if r.get("status") == "free"]
        if not available_spaces:
            logging.warning(f"No spaces with 'status: free' found at location {location_id}!")
        else:
            logging.info(f"Extracted free parking spaces at {location_id}: {', '.join(available_spaces)}")
        return available_spaces
    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred while fetching spaces: {e}")
        return []
    except (KeyError, TypeError) as e:
        logging.error(f"Failed to parse available spaces from response: {e}. Response: {response.text}")
        return []


def attempt_booking(session: requests.Session, token: str, target_date: str, space_id: str) -> bool:
    logging.info(f"Attempting to book parking spot {space_id} for {target_date}...")
    booking_url = f"{BASE_URL}/api/2.0/create-event"
    headers = {"Authorization": f"Bearer {token}"}

    start_time = f"{target_date}T{START_HOUR}:00+01:00"
    end_time = f"{target_date}T{END_HOUR}:00+01:00"
    dates_list = [{"startTime": start_time, "endTime": end_time}]
    
    payload = {
        "emailAddress": f"{MAIL_USER}",
        "dates": json.dumps(dates_list),
        "startTime": start_time,
        "endTime": end_time,
        "extras": "[]",
        "plateNumber": PLATE_NUMBER,
        "app": "web",
        "os": "Python",
        "resources": f"[{space_id}]"
    }

    try:
        response = session.post(booking_url, headers=headers, data=payload)
        response.raise_for_status()
        result = response.json().get("result")

        if result == "success":
            logging.info(f"Successfully booked parking spot {space_id} for {target_date}.")
            return True
        else:
            logging.warning(f"Failed to book parking spot {space_id}. Response: {response.text}")
            return False
    except requests.exceptions.RequestException as e:
        logging.error(f"An error occurred during booking attempt for space {space_id}: {e}")
        return False
    except (KeyError, TypeError) as e:
        logging.error(f"Failed to parse booking response for space {space_id}: {e}. Response: {response.text}")
        return False

def lambda_handler(event, context):
    if not PASSWORD:
        logging.error("PASSWORD_PARKING environment variable not set.")
        return {"statusCode": 500, "body": "Missing PASSWORD_PARKING env variable"}

    target_date = get_target_date()
    if not target_date:
        return {"statusCode": 200, "body": "Script not intended to run on weekends."}

    logging.info(f"Target date: {target_date}")

    if context and hasattr(context, 'get_remaining_time_in_millis'):
        timeout_ms = context.get_remaining_time_in_millis()
    else:
        timeout_ms = 60000
    start_time = time.time()

    with requests.Session() as session:
        session.headers.update({
            'Content-Type': 'application/x-www-form-urlencoded',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.36'
        })

        token = login(session)
        if not token:
            return {"statusCode": 500, "body": "Login failed"}

        forbidden_spaces = {"68": "2592", "69": "2591"}
        sleep_interval = 5

        while True:
            all_available = {}
            for loc_id in LOCATION_IDS:
                all_available[loc_id] = get_available_spaces(session, token, target_date, loc_id)

            booked = False
            for loc_id in LOCATION_IDS:
                for space_id in all_available[loc_id]:
                    if space_id not in forbidden_spaces.values():
                        if attempt_booking(session, token, target_date, space_id):
                            return {"statusCode": 200, "body": f"Booked space {space_id} at location {loc_id}"}
                        logging.warning(f"Failed to book space {space_id} at location {loc_id}. Trying next available space...")

            forbidden_candidates = []
            for loc_id in LOCATION_IDS:
                forbidden_candidates.extend([sid for sid in all_available[loc_id] if sid in forbidden_spaces.values()])
            if forbidden_candidates:
                space_id = random.choice(forbidden_candidates)
                if attempt_booking(session, token, target_date, space_id):
                    return {"statusCode": 200, "body": f"Booked forbidden space {space_id}"}
                logging.warning(f"Failed to book forbidden space {space_id}. Retrying...")

            logging.warning("No available spaces could be booked. Retrying...")
            elapsed = time.time() - start_time
            if elapsed + sleep_interval > timeout_ms / 1000:
                break
            time.sleep(sleep_interval)

    logging.warning("No available spaces could be booked after retries.")
    return {"statusCode": 404, "body": "No available spaces could be booked after retries."}

if __name__ == "__main__":
    lambda_handler({}, None) 