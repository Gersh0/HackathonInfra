from fastapi import APIRouter, Depends, HTTPException

from app.auth.jwt import create_access_token
from app.core.settings import settings
from app.dependencies import get_user_repository
from app.repositories.interfaces import UserRepositoryPort
from app.schemas.auth import AuthTokenRequest, AuthTokenResponse

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/token", response_model=AuthTokenResponse)
async def create_token(
    payload: AuthTokenRequest,
    user_repo: UserRepositoryPort = Depends(get_user_repository),
):
    if not (settings.is_development_like or settings.auth_token_issuer_enabled):
        raise HTTPException(status_code=403, detail="Token issuance endpoint is disabled in this environment")

    user = await user_repo.get_by_id(payload.user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    token, expires_in = create_access_token(user.id)
    return AuthTokenResponse(access_token=token, expires_in=expires_in)
