import pytest


def pytest_addoption(parser):
    parser.addoption(
        "--run-real-inference",
        action="store_true",
        default=False,
        help="Execute separately marked native Windows model integration tests",
    )


def pytest_collection_modifyitems(config, items):
    if not config.getoption("--run-real-inference"):
        skip = pytest.mark.skip(reason="Real model test: opt in with --run-real-inference")
        for item in items:
            if "real_inference" in item.keywords:
                item.add_marker(skip)
