#include <qt/symbian_input_dialog.h>
#include "ui_symbian_input_dialog.h"
#include <QLineEdit>

symbian_input_dialog::symbian_input_dialog(QWidget *parent) :
    QDialog(parent),
    max_length_(0x7FFFFFFF),
    secret_editor_(new QLineEdit(this)),
    ui(new Ui::SymbianInputDialog) {
    setAttribute(Qt::WA_DeleteOnClose);
    ui->setupUi(this);
    secret_editor_->setObjectName(QStringLiteral("secretLineEdit"));
    secret_editor_->setEchoMode(QLineEdit::Password);
    secret_editor_->setInputMethodHints(Qt::ImhHiddenText | Qt::ImhSensitiveData | Qt::ImhNoPredictiveText);
    secret_editor_->hide();
    ui->verticalLayout->insertWidget(0, secret_editor_);

    connect(ui->plainTextEdit, &QPlainTextEdit::textChanged, this, &symbian_input_dialog::event_content_changed);
    connect(ui->submitButton, &QPushButton::pressed, this, &symbian_input_dialog::event_submit_pressed);
    connect(this, &QDialog::finished, this, &symbian_input_dialog::event_finished);
}

symbian_input_dialog::~symbian_input_dialog() {
    delete ui;
}

void symbian_input_dialog::open_for_input(const QString &initial_text, const int new_max_length, const bool secret) {
    secret_ = secret;
    max_length_ = qMax(0, new_max_length);
    // Never put a secret in the unmasked QTextDocument, including on reuse.
    ui->plainTextEdit->clear();
    secret_editor_->clear();
    ui->plainTextEdit->setVisible(!secret_);
    secret_editor_->setVisible(secret_);
    if (secret_) {
        secret_editor_->setMaxLength(max_length_);
        secret_editor_->setText(initial_text);
        secret_editor_->setFocus();
    } else {
        ui->plainTextEdit->setPlainText(initial_text);
        ui->plainTextEdit->setFocus();
    }

    show();
}

void symbian_input_dialog::event_submit_pressed() {
    emit finished_input(get_current_text(), false);
}

void symbian_input_dialog::event_finished(int result) {
    if (result == QDialog::Rejected) {
        emit finished_input(QString{}, true);
    }
}

void symbian_input_dialog::event_content_changed() {
    // Code grabbed from forum! (Mar4eli)
    // https://forum.qt.io/topic/23725/solved-limit-number-of-characters-in-qtextedit/3
    if (!secret_ && ui->plainTextEdit->toPlainText().length() > max_length_) {
        int diff = ui->plainTextEdit->toPlainText().length() - max_length_; //m_maxTextEditLength - just an integer
        QString newStr = ui->plainTextEdit->toPlainText();
        newStr.chop(diff);
        ui->plainTextEdit->setPlainText(newStr);

        // Move the cursor to the end
        QTextCursor cursor(ui->plainTextEdit->textCursor());
        cursor.movePosition(QTextCursor::End, QTextCursor::MoveAnchor);
        ui->plainTextEdit->setTextCursor(cursor);
    }
}

QString symbian_input_dialog::get_current_text() const {
    return secret_ ? secret_editor_->text() : ui->plainTextEdit->toPlainText();
}