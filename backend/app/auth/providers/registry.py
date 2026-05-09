from fastapi import HTTPException

from app.auth.providers.local import LocalUserProvider
from app.auth.providers.base import UserProvider


class UserProviderRegistry:
    def __init__(self):
        local = LocalUserProvider()
        self._providers: dict[str, UserProvider] = {
            local.provider_name: local,
            # Register external providers in the future (cognito, firebase, ...)
        }

    def get(self, provider_name: str) -> UserProvider:
        provider = self._providers.get(provider_name)
        if provider is None:
            supported = ", ".join(sorted(self._providers.keys()))
            raise HTTPException(status_code=400, detail=f"Unsupported provider '{provider_name}'. Supported providers: {supported}")
        return provider

    def list_provider_names(self) -> list[str]:
        return sorted(self._providers.keys())
