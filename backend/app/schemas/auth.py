from pydantic import BaseModel, Field


class AuthTokenRequest(BaseModel):
    user_id: int = Field(ge=1)


class AuthTokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int
