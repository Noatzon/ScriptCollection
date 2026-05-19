'@Fishdust 2026, https://github.com/Noatzon/ScriptCollection

Sub Main()
wb = ThisWorkbook.Name
Application.Workbooks(wb).Activate

With Sheets("Sheet1")


i = .Range("A" & Rows.Count).End(xlUp).Row + 1 'otherwise main loop will always skip last row/field

    For rc = 2 To i Step 1
        user = .Cells(rc, 4).Value '"E-mail" column
        str1 = .Cells(rc, 6).Value '"Result" column. Get all the options they selected into a string.
        arrSplit1 = Split(str1, ";") 'Create array
        
        'New loop to actually process each item in the array.
        For d = LBound(arrSplit1, 1) To UBound(arrSplit1, 1)
             str2 = arrSplit1(d) 'The value we're currently working with in the array.
            
            'Giant loop to check which options were selected. When matched, put user in that sheet. Am stupied so making it clunkier than needed.
            'Matched option 1
            If str2 Like "Lemonade*" Then
                    With Sheets("Lemon")
                        y = .Range("A" & Rows.Count).End(xlUp).Row + 1 'So we always write on a new row/line
                        .Cells(y, 1).Value = user
                    End With
                    
            'Matched  option 2 etc
            ElseIf str2 Like "*Catnip*" Then
                    With Sheets("Cats")
                        y = .Range("A" & Rows.Count).End(xlUp).Row + 1 'So we always write on a new row/line
                        .Cells(y, 1).Value = user
                    End With
                                        
             End If
        Next
              
              
    Next
    
End With
End Sub


'To clean all sheets (used only during development)
Sub Del()
    With Sheets("Lemonade")
        h = .Range("A" & Rows.Count).End(xlUp).Row
        For i = h To 1 Step -1
            .Rows(i).Delete
        Next
    End With
    With Sheets("Cats")
        h = .Range("A" & Rows.Count).End(xlUp).Row
        For i = h To 1 Step -1
            .Rows(i).Delete
        Next
    End With
End Sub


'Run to create .csv file for importing into Azure
Sub Export()
    Dim bFileSaveAs As Boolean
    Dim n As Long
    Dim t, sn As String
    't = Format([=NOW()], "yyyy-mm-dd_hhmm")
    wbv = ThisWorkbook.Name
    
    
    For n = 2 To ThisWorkbook.Worksheets.Count
        Worksheets(n).Activate
        sn = ActiveSheet.Name
        Sheets(n).Copy
            'xlDialogSaveAs  document_text, type_num, - So first is document name, next is "save as", with a number corresponding to a format. For us that's "UTF-8 CSV (comma seperated)"
        'bFileSaveAs = Application.Dialogs(xlDialogSaveAs).Show("ImportGroupMembersTemplate" & t, 62)
        bFileSaveAs = Application.Dialogs(xlDialogSaveAs).Show("ImportGroupMembersTemplate" & "-" & sn, 62)
        If Not bFileSaveAs Then
            MsgBox "User cancelled", vbCritical
            Else
        End If
        wb = "ImportGroupMembersTemplate" & "-" & sn & ".csv"
        Application.Workbooks(wb).Close
        Application.Workbooks(wbv).Activate
    Next n
End Sub
