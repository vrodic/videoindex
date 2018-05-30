from setuptools import setup

setup(
    name='videoindex',
    packages=['videoindex'],
    include_package_data=True,
    install_requires=[
        'ffmpeg-python',
    ],
)