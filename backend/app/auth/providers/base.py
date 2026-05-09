from dataclasses import dataclass
from typing import Protocol


@dataclass
class ProviderUserCreateInput:
    display_name: str
    provider_subject: str
    email: str | None
    avatar_path: str | None


class UserProvider(Protocol):
    provider_name: str

    def normalize_subject(self, payload: ProviderUserCreateInput) -> str:
        ...


class UserProviderRegistryPort(Protocol):
    def get(self, provider_name: str) -> UserProvider:
        ...

    def list_provider_names(self) -> list[str]:
        ...
