BACKGROUND & USECASE
You're using [Intune] & [Microsoft Entra ID] for user management in a large organization. For one reason or another you need the end user to inform you which groups they need to be part of. One solution to this is creating a [Microsoft Forms] form with the different groups as options in a multi-answer question. Share this form with your users and you'll end up with an [Excel] file at the end containing all the users and which options they picked. 

CODE EXPLANATION
See the screenshot for reference to the form setup used in the "default" code. Remember to toggle the option to allow "multiple answers"! There's nothing stopping you from having more than one "question" in the form, you just have to duplicate code and tweak which column is being used for each additional question in it.

• Download a copy of the Excel workbook created by [Microsoft Forms] and save as macro enabled. 
- Create a new module and C+P the VBA code into it.
- Run Main() sub to populate sheets & Export() ssub to create the files for [Azure].
• You need to create a sheet for each of the groups/options in your form. Update code accordingly (add Elseif blocks for each sheet/option).
- You can quite easily tweak code to auto-generate the sheets during runtime by simply taking the values from the array and check the "workbook collection" for a sheet with that name, create one if it's not present or use existing one if found. This was a rushjob so I just bruteforced it. (๏ᆺ๏υ)
• The Export() sub is built on madness & black magic. As Todd Howards would say - "It just works" ( ͡° ͜ʖ ͡° )
1. Running it will loop through each sheet except the first one (since this one just contain the raw data). 
2. Create a copy/temporary workbook containing only that sheet and automatically open up the "Save" dialog window with name & fileformat already prepopulated. 
3. Once you've selected where to save it and hit "Save" it will then close the temporary workbook and move on to next sheet, repeating until done.

//Fishdust 2026, https://github.com/Noatzon/ScriptCollection