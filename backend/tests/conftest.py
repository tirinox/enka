"""Test harness.

Tests run against a real Postgres — the same one compose starts — in a
throwaway `enka_test` database built by running the actual Alembic migrations.
That is deliberate: pg_trgm, unaccent, the `f_unaccent` wrapper and the
expression indexes are load-bearing features here, and a SQLite stand-in would
test none of them (and would let a broken migration through).

Each test runs inside a transaction that is rolled back afterwards, so tests
are isolated without paying to recreate the schema every time.
"""

from __future__ import annotations

import asyncio
import io
import struct
import uuid
import wave
from collections.abc import AsyncIterator

import pytest
import pytest_asyncio
from alembic import command
from alembic.config import Config
from httpx import ASGITransport, AsyncClient
from sqlalchemy.engine.url import make_url
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine

from app.api.deps import get_current_owner, get_storage
from app.core.config import settings
from app.core.security import create_token, login_throttle
from app.db.session import get_session
from app.models.owner import Owner
from app.storage.local import LocalStorage

TEST_DB_NAME = "enka_test"
TEST_SECRET = "test-access-secret"


# --------------------------------------------------------------- settings ---
@pytest.fixture(scope="session", autouse=True)
def _configure_settings(tmp_path_factory) -> None:
    """Point the singleton settings at test values before anything uses them."""
    settings.access_secret = TEST_SECRET
    # At least 32 bytes, or PyJWT warns about the key being short for HS256.
    settings.jwt_secret = "test-jwt-signing-key-padded-to-thirty-two-bytes"
    settings.audio_dir = str(tmp_path_factory.mktemp("audio"))
    settings.max_audio_mb = 1
    # Deterministic intervals — fuzz would make interval assertions flaky.
    settings.fsrs_enable_fuzzing = False


@pytest.fixture(autouse=True)
def _reset_throttle() -> None:
    """The login throttle is process-global; don't leak state between tests."""
    login_throttle._hits.clear()


# --------------------------------------------------------------- database ---
def _url_for(database: str) -> str:
    # render_as_string(hide_password=False) is required — plain str() on a
    # SQLAlchemy URL replaces the password with '***'.
    return (
        make_url(settings.database_url).set(database=database).render_as_string(hide_password=False)
    )


def _test_database_url() -> str:
    return _url_for(TEST_DB_NAME)


async def _recreate_database() -> None:
    admin_url = _url_for("postgres")
    engine = create_async_engine(admin_url, isolation_level="AUTOCOMMIT")
    async with engine.connect() as conn:
        await conn.exec_driver_sql(f"DROP DATABASE IF EXISTS {TEST_DB_NAME} WITH (FORCE)")
        await conn.exec_driver_sql(f"CREATE DATABASE {TEST_DB_NAME}")
    await engine.dispose()


def _run_migrations(url: str) -> None:
    # env.py reads settings.database_url and calls asyncio.run(), so this has
    # to happen off the running loop — hence the to_thread call below.
    previous = settings.database_url
    settings.database_url = url
    try:
        cfg = Config("alembic.ini")
        cfg.set_main_option("script_location", "migrations")
        command.upgrade(cfg, "head")
    finally:
        settings.database_url = previous


@pytest_asyncio.fixture(scope="session")
async def engine():
    await _recreate_database()
    url = _test_database_url()
    await asyncio.to_thread(_run_migrations, url)

    test_engine = create_async_engine(url, poolclass=None)
    yield test_engine
    await test_engine.dispose()


@pytest_asyncio.fixture
async def db(engine) -> AsyncIterator[AsyncSession]:
    """A session whose work is rolled back when the test ends.

    ``join_transaction_mode="create_savepoint"`` lets application code call
    commit() normally — it releases a savepoint rather than the outer
    transaction, so the rollback below still undoes everything.
    """
    async with engine.connect() as conn:
        outer = await conn.begin()
        session = AsyncSession(
            bind=conn, join_transaction_mode="create_savepoint", expire_on_commit=False
        )
        try:
            yield session
        finally:
            await session.close()
            if outer.is_active:
                await outer.rollback()


@pytest_asyncio.fixture
async def owner(db: AsyncSession) -> Owner:
    row = Owner(name="tester")
    db.add(row)
    await db.commit()
    await db.refresh(row)
    return row


# ------------------------------------------------------------------ client --
@pytest_asyncio.fixture
async def app_client(db: AsyncSession, tmp_path) -> AsyncIterator[AsyncClient]:
    """Unauthenticated client. Lifespan is skipped on purpose — fixtures own
    owner seeding, and the real lifespan would talk to the dev database."""
    from app.main import app

    async def _session_override() -> AsyncIterator[AsyncSession]:
        yield db

    storage = LocalStorage(tmp_path / "audio")
    app.dependency_overrides[get_session] = _session_override
    app.dependency_overrides[get_storage] = lambda: storage

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        client.storage = storage  # type: ignore[attr-defined]
        yield client

    app.dependency_overrides.clear()


@pytest_asyncio.fixture
async def client(app_client: AsyncClient, owner: Owner) -> AsyncClient:
    """Authenticated client — the one most tests want."""
    token, _ = create_token(owner.id)
    app_client.headers["Authorization"] = f"Bearer {token}"
    return app_client


@pytest.fixture
def anon_client(app_client: AsyncClient) -> AsyncClient:
    return app_client


@pytest.fixture
def force_owner(owner: Owner):
    """Bypass token checks for tests that aren't about auth."""
    from app.main import app

    app.dependency_overrides[get_current_owner] = lambda: owner
    yield owner
    app.dependency_overrides.pop(get_current_owner, None)


# ------------------------------------------------------------------ audio ---
@pytest.fixture
def wav_bytes() -> bytes:
    """A real, playable 100 ms mono WAV — not a header stub."""
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(8000)
        handle.writeframes(struct.pack("<800h", *([0] * 800)))
    return buffer.getvalue()


@pytest.fixture
def mp3_bytes() -> bytes:
    """ID3v2 header followed by an MPEG frame sync — what a real mp3 starts with."""
    return b"ID3\x03\x00\x00\x00\x00\x00\x00" + b"\xff\xfb\x90\x00" + b"\x00" * 512


@pytest.fixture
def ogg_bytes() -> bytes:
    return b"OggS\x00\x02" + b"\x00" * 512


# ------------------------------------------------------------------ helpers -
async def make_card(client: AsyncClient, term: str, definition: str | None = None, **extra):
    payload = {"term": term, "definition": definition, **extra}
    response = await client.post("/api/v1/cards", json=payload)
    assert response.status_code == 201, response.text
    return response.json()


@pytest.fixture
def card_factory(client: AsyncClient):
    async def factory(term: str, definition: str | None = None, **extra):
        return await make_card(client, term, definition, **extra)

    return factory


@pytest.fixture
def new_uuid():
    return lambda: str(uuid.uuid4())
