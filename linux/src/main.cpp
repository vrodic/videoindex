#include <QApplication>
#include <iostream>
#include "MainWindow.h"

int main(int argc, char* argv[]) {
    if (argc < 3) {
        std::cerr << "Usage: VideoIndex <root_dir> <index_file>" << std::endl;
        return 1;
    }

    QApplication app(argc, argv);
    app.setApplicationName("videoindex");
    app.setOrganizationName("VideoIndex");

    QString rootDir = QString::fromUtf8(argv[1]);
    QString indexFile = QString::fromUtf8(argv[2]);

    MainWindow mainWindow(rootDir, indexFile);
    mainWindow.show();

    return app.exec();
}
