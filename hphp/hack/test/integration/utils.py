# pyre-strict

from __future__ import absolute_import, division, print_function, unicode_literals

import os
import re
import signal
from types import FrameType
from typing import BinaryIO, Callable, Iterable, Mapping, Union


try:
    from typing import ForwardRef
except ImportError:
    from typing import _ForwardRef as ForwardRef

JsonObject = Mapping[str, ForwardRef("Json")]
JsonArray = Iterable[ForwardRef("Json")]
JsonScalar = Union[str, int, float, bool, None]
Json = Union[JsonObject, JsonArray, JsonScalar]

VariableMap = Mapping[str, str]


def touch(fn: str) -> None:
    with open(fn, "a"):
        os.utime(fn, None)


def write_files(files: Mapping[str, str], dir_path: str) -> None:
    """
    Write a bunch of files into the directory at dir_path.

    files: dict of file name => file contents
    """
    for fn, content in files.items():
        path = os.path.join(dir_path, fn)
        with open(path, "w") as f:
            f.write(content)


def ensure_output_contains(f: BinaryIO, s: str, timeout: int = 20) -> None:
    """
    Looks for a match in a process' output, subject to a timeout in case the
    process hangs
    """
    lines = []

    def handler(signo: int, frame: FrameType) -> None:
        raise AssertionError(
            "Failed to find %s in the following output: %s" % (s, "".join(lines))
        )

    try:
        signal.signal(signal.SIGALRM, handler)
        signal.alarm(timeout)
        while True:
            line = f.readline().decode("utf-8")
            if s in line:
                return
            lines.append(line)
    finally:
        signal.alarm(0)


def map_json_scalars(json: Json, f: Callable[[JsonScalar], JsonScalar]) -> Json:
    if isinstance(json, dict):
        return {
            map_json_scalars(json=k, f=f): map_json_scalars(json=v, f=f)
            for k, v in json.items()
        }
    elif isinstance(json, list):
        return [map_json_scalars(json=i, f=f) for i in json]
    elif isinstance(json, (str, int, float, bool, type(None))):
        return f(json)
    else:
        assert False, f"Unhandled JSON case: {json.__class__.__name__}"


# Because HHI folders are different for each process,
# let's just standardize them
def fixup_hhi_json(payload: Json) -> Json:
    def interpolate(json: JsonScalar) -> JsonScalar:
        if isinstance(json, str):
            json = re.sub(
                "/tmp/tmp[\\d\\w_]*/hhi_[\\dabcdef]*/", "/tmp/cleansed_hhi_path/", json
            )
        return json

    return map_json_scalars(json=payload, f=interpolate)


def interpolate_variables(payload: Json, variables: VariableMap) -> Json:
    def interpolate(json: JsonScalar) -> JsonScalar:
        if isinstance(json, str):
            for variable, value in variables.items():
                json = json.replace("${" + variable + "}", value)
            if "${" in json:
                raise ValueError(
                    f"There was an undefined ${{}}-variable "
                    + f"in this JSON value: {json!r}. "
                    + f"Make sure that you have initialized everything correctly and "
                    + f"passed the correct variable map "
                    + f"to {interpolate_variables.__name__}. "
                    + f"It is currently: {variables!r}"
                )
        return json

    return map_json_scalars(json=payload, f=interpolate)


def uninterpolate_variables(payload: Json, variables: VariableMap) -> Json:
    # Sort so that we process the variable with the longest-length bindings first.
    variable_bindings = sorted(
        variables.items(), key=lambda kv: len(kv[1]), reverse=True
    )

    for variable, value in variable_bindings:

        def uninterpolate(json: JsonScalar) -> JsonScalar:
            if isinstance(json, str):
                return json.replace(value, "${" + variable + "}")
            else:
                return json

        payload = map_json_scalars(json=payload, f=uninterpolate)
    return payload
