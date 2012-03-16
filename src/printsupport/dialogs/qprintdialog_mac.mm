/****************************************************************************
**
** Copyright (C) 2012 Nokia Corporation and/or its subsidiary(-ies).
** Contact: http://www.qt-project.org/
**
** This file is part of the QtGui module of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:LGPL$
** GNU Lesser General Public License Usage
** This file may be used under the terms of the GNU Lesser General Public
** License version 2.1 as published by the Free Software Foundation and
** appearing in the file LICENSE.LGPL included in the packaging of this
** file. Please review the following information to ensure the GNU Lesser
** General Public License version 2.1 requirements will be met:
** http://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
**
** In addition, as a special exception, Nokia gives you certain additional
** rights. These rights are described in the Nokia Qt LGPL Exception
** version 1.1, included in the file LGPL_EXCEPTION.txt in this package.
**
** GNU General Public License Usage
** Alternatively, this file may be used under the terms of the GNU General
** Public License version 3.0 as published by the Free Software Foundation
** and appearing in the file LICENSE.GPL included in the packaging of this
** file. Please review the following information to ensure the GNU General
** Public License version 3.0 requirements will be met:
** http://www.gnu.org/copyleft/gpl.html.
**
** Other Usage
** Alternatively, this file may be used in accordance with the terms and
** conditions contained in a signed written agreement between you and Nokia.
**
**
**
**
**
**
** $QT_END_LICENSE$
**
****************************************************************************/

#ifndef QT_NO_PRINTDIALOG

#include <Cocoa/Cocoa.h>

#include "qprintdialog.h"
#include "qabstractprintdialog_p.h"

#include <QtCore/qhash.h>
#include <QtCore/private/qcore_mac_p.h>
#include <QtWidgets/private/qapplication_p.h>
#include <QtPrintSupport/qprinter.h>
#include <QtPrintSupport/qprintengine.h>

QT_BEGIN_NAMESPACE

class QPrintDialogPrivate : public QAbstractPrintDialogPrivate
{
    Q_DECLARE_PUBLIC(QPrintDialog)

public:
    QPrintDialogPrivate() : printInfo(0), printPanel(0)
       {}

    void openCocoaPrintPanel(Qt::WindowModality modality);
    void closeCocoaPrintPanel();

    inline QPrintDialog *printDialog() { return q_func(); }

    inline void _q_printToFileChanged(int) {}
    inline void _q_rbPrintRangeToggled(bool) {}
    inline void _q_printerChanged(int) {}
#ifndef QT_NO_MESSAGEBOX
    inline void _q_checkFields() {}
#endif
    inline void _q_chbPrintLastFirstToggled(bool) {}
    inline void _q_paperSizeChanged(int) {}
    inline void _q_btnBrowseClicked() {}
    inline void _q_btnPropertiesClicked() {}

    NSPrintInfo *printInfo;
    NSPrintPanel *printPanel;
};

QT_END_NAMESPACE

QT_USE_NAMESPACE


@class QT_MANGLE_NAMESPACE(QCocoaPrintPanelDelegate);

@interface QT_MANGLE_NAMESPACE(QCocoaPrintPanelDelegate) : NSObject
{
    NSPrintInfo *printInfo;
}
- (id)initWithNSPrintInfo:(NSPrintInfo *)nsPrintInfo;
- (void)printPanelDidEnd:(NSPrintPanel *)printPanel
        returnCode:(int)returnCode contextInfo:(void *)contextInfo;
@end

@implementation QT_MANGLE_NAMESPACE(QCocoaPrintPanelDelegate)
- (id)initWithNSPrintInfo:(NSPrintInfo *)nsPrintInfo
{
    if (self = [super init]) {
        printInfo = nsPrintInfo;
    }
    return self;
}
- (void)printPanelDidEnd:(NSPrintPanel *)printPanel
        returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
    Q_UNUSED(printPanel);

    QPrintDialog *dialog = static_cast<QPrintDialog *>(contextInfo);
    QPrinter *printer = dialog->printer();

    if (returnCode == NSOKButton) {
        PMPrintSession session = static_cast<PMPrintSession>([printInfo PMPrintSession]);
        PMPrintSettings settings = static_cast<PMPrintSettings>([printInfo PMPrintSettings]);

        UInt32 frompage, topage;
        PMGetFirstPage(settings, &frompage);
        PMGetLastPage(settings, &topage);
        topage = qMin(UInt32(INT_MAX), topage);
        dialog->setFromTo(frompage, topage);

        // OK, I need to map these values back let's see
        // If from is 1 and to is INT_MAX, then print it all
        // (Apologies to the folks with more than INT_MAX pages)
        if (dialog->fromPage() == 1 && dialog->toPage() == INT_MAX) {
            dialog->setPrintRange(QPrintDialog::AllPages);
            dialog->setFromTo(0, 0);
        } else {
            dialog->setPrintRange(QPrintDialog::PageRange); // In a way a lie, but it shouldn't hurt.
            // Carbon hands us back a very large number here even for ALL, set it to max
            // in that case to follow the behavior of the other print dialogs.
            if (dialog->maxPage() < dialog->toPage())
                dialog->setFromTo(dialog->fromPage(), dialog->maxPage());
        }
        // Keep us in sync with file output
        PMDestinationType dest;

        // If the user selected print to file, the session has been
        // changed behind our back and our d->ep->session object is a
        // dangling pointer. Update it based on the "current" session
        PMSessionGetDestinationType(session, settings, &dest);
        if (dest == kPMDestinationFile) {
            QCFType<CFURLRef> file;
            PMSessionCopyDestinationLocation(session, settings, &file);
            UInt8 localFile[2048];  // Assuming there's a POSIX file system here.
            CFURLGetFileSystemRepresentation(file, true, localFile, sizeof(localFile));
            printer->setOutputFileName(QString::fromUtf8(reinterpret_cast<const char *>(localFile)));
        } else {
            // Keep output format.
            QPrinter::OutputFormat format;
            format = printer->outputFormat();
            printer->setOutputFileName(QString());
            printer->setOutputFormat(format);
        }
    }

    dialog->done((returnCode == NSOKButton) ? QDialog::Accepted : QDialog::Rejected);
}
@end

QT_BEGIN_NAMESPACE

void QPrintDialogPrivate::openCocoaPrintPanel(Qt::WindowModality modality)
{
    Q_Q(QPrintDialog);

    // get the NSPrintInfo from the print engine in the platform plugin
    void *voidp = 0;
    (void) QMetaObject::invokeMethod(qApp->platformNativeInterface(),
                                     "NSPrintInfoForPrintEngine",
                                     Q_RETURN_ARG(void *, voidp),
                                     Q_ARG(QPrintEngine *, printer->printEngine()));
    printInfo = static_cast<NSPrintInfo *>(voidp);
    [printInfo retain];

    // It seems the only way that PM lets you use all is if the minimum
    // for the page range is 1. This _kind of_ makes sense if you think about
    // it. However, calling PMSetFirstPage() or PMSetLastPage() always enforces
    // the range.
    // get print settings from the platform plugin
    PMPrintSettings settings = static_cast<PMPrintSettings>([printInfo PMPrintSettings]);
    PMSetPageRange(settings, q->minPage(), q->maxPage());
    if (q->printRange() == QAbstractPrintDialog::PageRange) {
        PMSetFirstPage(settings, q->fromPage(), false);
        PMSetLastPage(settings, q->toPage(), false);
    }
    [printInfo updateFromPMPrintSettings];

    QPrintDialog::PrintDialogOptions qtOptions = q->options();
    NSPrintPanelOptions macOptions = NSPrintPanelShowsCopies;
    if (qtOptions & QPrintDialog::PrintPageRange)
        macOptions |= NSPrintPanelShowsPageRange;
    if (qtOptions & QPrintDialog::PrintShowPageSize)
        macOptions |= NSPrintPanelShowsPaperSize | NSPrintPanelShowsPageSetupAccessory
                      | NSPrintPanelShowsOrientation;

    printPanel = [NSPrintPanel printPanel];
    [printPanel retain];
    [printPanel setOptions:macOptions];

    QT_MANGLE_NAMESPACE(QCocoaPrintPanelDelegate) *delegate = [[QT_MANGLE_NAMESPACE(QCocoaPrintPanelDelegate) alloc] init];
    if (modality == Qt::ApplicationModal) {
        int rval = [printPanel runModalWithPrintInfo:printInfo];
        [delegate printPanelDidEnd:printPanel returnCode:rval contextInfo:this];
    } else {
        Q_ASSERT(q->parentWidget());
        QWindow *parentWindow = q->parentWidget()->windowHandle();
        NSWindow *window = static_cast<NSWindow *>(qApp->platformNativeInterface()->nativeResourceForWindow("nswindow", parentWindow));
        [printPanel beginSheetWithPrintInfo:printInfo
                             modalForWindow:window
                                   delegate:delegate
                             didEndSelector:@selector(printPanelDidEnd:returnCode:contextInfo:)
                                contextInfo:this];
    }
}

void QPrintDialogPrivate::closeCocoaPrintPanel()
{
    [printInfo release];
    printInfo = 0;
    [printPanel release];
    printPanel = 0;
}

static bool warnIfNotNative(QPrinter *printer)
{
    if (printer->outputFormat() != QPrinter::NativeFormat) {
        qWarning("QPrintDialog: Cannot be used on non-native printers");
        return false;
    }
    return true;
}


QPrintDialog::QPrintDialog(QPrinter *printer, QWidget *parent)
    : QAbstractPrintDialog(*(new QPrintDialogPrivate), printer, parent)
{
    Q_D(QPrintDialog);
    if (!warnIfNotNative(d->printer))
        return;
}

QPrintDialog::QPrintDialog(QWidget *parent)
    : QAbstractPrintDialog(*(new QPrintDialogPrivate), 0, parent)
{
    Q_D(QPrintDialog);
    if (!warnIfNotNative(d->printer))
        return;
}

QPrintDialog::~QPrintDialog()
{
}

int QPrintDialog::exec()
{
    Q_D(QPrintDialog);
    if (!warnIfNotNative(d->printer))
        return QDialog::Rejected;

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    d->openCocoaPrintPanel(Qt::ApplicationModal);
    d->closeCocoaPrintPanel();
    [pool release];
    return result();
}


/*!
    \reimp
*/
void QPrintDialog::setVisible(bool visible)
{
    Q_D(QPrintDialog);

    bool isCurrentlyVisible = (d->printPanel != 0);

    if (!visible == !isCurrentlyVisible)
        return;

    if (d->printer->outputFormat() != QPrinter::NativeFormat)
        return;

    if (visible) {
        d->openCocoaPrintPanel(parentWidget() ? Qt::WindowModal
                                              : Qt::ApplicationModal);
        return;
    } else {
        if (d->printPanel) {
            d->closeCocoaPrintPanel();
            return;
        }
    }
}

QT_END_NAMESPACE

#include "moc_qprintdialog.cpp"

#endif // QT_NO_PRINTDIALOG
