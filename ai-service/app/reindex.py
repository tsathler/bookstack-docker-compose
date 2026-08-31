from __future__ import annotations

import asyncio
import hashlib
import sqlite3
from contextlib import closing

import httpx

from .main import clean_content, database_path, initialize_database, settings


async def api_get(client: httpx.AsyncClient, path: str, params: dict | None = None) -> dict:
    response = await client.get(f"{settings.bookstack_url.rstrip('/')}/api/{path.lstrip('/')}", params=params)
    response.raise_for_status()
    return response.json()


async def main() -> None:
    initialize_database()
    headers = {
        "Authorization": f"Token {settings.bookstack_api_token_id}:{settings.bookstack_api_token_secret}",
        "Accept": "application/json",
    }
    async with httpx.AsyncClient(headers=headers, timeout=settings.request_timeout_seconds) as client:
        page_number = 1
        pages: list[dict] = []
        while True:
            payload = await api_get(client, "pages", {"count": 100, "page": page_number})
            batch = payload.get("data", [])
            pages.extend(batch)
            if len(batch) < 100:
                break
            page_number += 1

        records = []
        for item in pages:
            detail = await api_get(client, f"pages/{item['id']}")
            content = clean_content(detail.get("html") or detail.get("markdown") or detail.get("content") or "")
            records.append((detail["id"], detail.get("name", "Sem título"), detail.get("web_url", ""), content,
                            hashlib.sha256(content.encode("utf-8")).hexdigest()))

    with closing(sqlite3.connect(database_path())) as db:
        db.execute("DELETE FROM pages_fts")
        db.execute("DELETE FROM pages")
        db.executemany("INSERT INTO pages VALUES (?, ?, ?, ?, ?)", records)
        db.executemany("INSERT INTO pages_fts(rowid, title, content) VALUES (?, ?, ?)",
                       [(r[0], r[1], r[3]) for r in records])
        db.commit()
    print(f"Indexed {len(records)} BookStack pages")


if __name__ == "__main__":
    asyncio.run(main())
