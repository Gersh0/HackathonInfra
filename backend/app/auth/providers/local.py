import uuid

from app.auth.providers.base import ProviderUserCreateInput


class LocalUserProvider:
    provider_name = "local"

    def normalize_subject(self, payload: ProviderUserCreateInput) -> str:
        if payload.provider_subject.strip():
            return payload.provider_subject.strip()
        return str(uuid.uuid4())
