"""A single error shape for every failure, so clients parse one thing.

{"error": {"code": "not_found", "message": "...", "details": {...}}}
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Request, status
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException


class EnkaError(Exception):
    """Base class for errors we raise deliberately."""

    status_code: int = status.HTTP_400_BAD_REQUEST
    code: str = "error"

    def __init__(self, message: str, details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.details = details or {}


class NotFoundError(EnkaError):
    status_code = status.HTTP_404_NOT_FOUND
    code = "not_found"


class ConflictError(EnkaError):
    status_code = status.HTTP_409_CONFLICT
    code = "conflict"


class ValidationError(EnkaError):
    status_code = status.HTTP_422_UNPROCESSABLE_CONTENT
    code = "validation_error"


class UnauthorizedError(EnkaError):
    status_code = status.HTTP_401_UNAUTHORIZED
    code = "unauthorized"


class RateLimitedError(EnkaError):
    status_code = status.HTTP_429_TOO_MANY_REQUESTS
    code = "rate_limited"


class PayloadTooLargeError(EnkaError):
    status_code = status.HTTP_413_CONTENT_TOO_LARGE
    code = "payload_too_large"


class UnsupportedMediaTypeError(EnkaError):
    status_code = status.HTTP_415_UNSUPPORTED_MEDIA_TYPE
    code = "unsupported_media_type"


def error_body(code: str, message: str, details: dict[str, Any] | None = None) -> dict[str, Any]:
    return {"error": {"code": code, "message": message, "details": details or {}}}


_STATUS_CODES = {
    400: "bad_request",
    401: "unauthorized",
    403: "forbidden",
    404: "not_found",
    405: "method_not_allowed",
    409: "conflict",
    413: "payload_too_large",
    415: "unsupported_media_type",
    416: "range_not_satisfiable",
    429: "rate_limited",
    500: "internal_error",
}


def register_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(EnkaError)
    async def _enka(_: Request, exc: EnkaError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content=error_body(exc.code, exc.message, exc.details),
            headers={"WWW-Authenticate": "Bearer"} if exc.status_code == 401 else None,
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        code = _STATUS_CODES.get(exc.status_code, "error")
        return JSONResponse(
            status_code=exc.status_code,
            content=error_body(code, str(exc.detail)),
            headers=exc.headers,
        )

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, exc: RequestValidationError) -> JSONResponse:
        return JSONResponse(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            content=error_body(
                "validation_error",
                "Request body or parameters failed validation.",
                # jsonable_encoder is required: Pydantic puts the original
                # exception object in each error's `ctx`, which json can't
                # serialise on its own.
                {"errors": jsonable_encoder(exc.errors())},
            ),
        )
